module router

import viltrum.http1

// Router matches method + path to a handler chain without allocating. Routes
// without params are found with one hash lookup on the request path; routes with
// :params or a trailing *wildcard walk the path bytes.

pub const not_found = -1
pub const method_not_allowed = -2
pub const max_params = 8

enum SegKind {
	lit
	param
	wild
}

struct Seg {
	kind SegKind
	text string
}

pub struct Route {
pub:
	method      http1.Method
	pattern     string
	chain       []http1.Handler
	param_names []string
mut:
	segs   []Seg
	static bool
}

pub struct Match {
pub mut:
	n     int
	spans [max_params]http1.Span // offsets into the path string
}

@[heap]
pub struct Router {
pub mut:
	routes []Route
	on_404 []http1.Handler // chain for a miss; empty means a plain-text 404
	on_405 []http1.Handler // chain for a method mismatch; empty means a plain-text 405
mut:
	statics [10]map[string]int // per Method: normalized path -> route index
}

// add registers pattern ('/users/:id', '/files/*rest'). cold: registration only.
pub fn (mut r Router) add(method http1.Method, pattern string, chain []http1.Handler) ! {
	mut segs := []Seg{}
	mut names := []string{}
	parts := pattern.split('/')
	for i, p in parts {
		if p.len == 0 {
			continue
		}
		if p[0] == `:` {
			if p.len == 1 {
				return error('router: empty param name in ${pattern}')
			}
			segs << Seg{
				kind: .param
				text: p[1..]
			}
			names << p[1..]
		} else if p[0] == `*` {
			if p.len == 1 {
				return error('router: unnamed wildcard in ${pattern}')
			}
			if parts[i + 1..].any(it.len > 0) {
				return error('router: wildcard must be last in ${pattern}')
			}
			segs << Seg{
				kind: .wild
				text: p[1..]
			}
			names << p[1..]
		} else {
			segs << Seg{
				kind: .lit
				text: p
			}
		}
	}
	if names.len > max_params {
		return error('router: more than ${max_params} params in ${pattern}')
	}
	idx := r.routes.len
	r.routes << Route{
		method:      method
		pattern:     pattern
		chain:       chain
		param_names: names
		segs:        segs
		static:      names.len == 0
	}
	if names.len == 0 {
		key := '/' + segs.map(it.text).join('/')
		if key !in r.statics[int(method)] {
			r.statics[int(method)][key] = idx
		}
	}
}

// find returns the route index for method and path, or not_found /
// method_not_allowed. Param spans in m are offsets into path. HEAD falls back to GET.
pub fn (r &Router) find(method http1.Method, path string, mut m Match) int {
	mut plen := path.len
	for plen > 1 && path[plen - 1] == `/` {
		plen--
	}
	idx := r.find_method(method, path, plen, mut m)
	if idx >= 0 {
		return idx
	}
	if method == .head {
		g := r.find_method(.get, path, plen, mut m)
		if g >= 0 {
			return g
		}
	}
	for i in 0 .. r.routes.len {
		if r.routes[i].method != method && match_segs(r.routes[i].segs, path, plen, mut m) {
			return method_not_allowed
		}
	}
	return not_found
}

// allowed returns the methods with a route for path, one bit per http1.Method (HEAD
// whenever GET), for the Allow header of a 405. cold: only a 405 calls it.
pub fn (r &Router) allowed(path string) u16 {
	mut plen := path.len
	for plen > 1 && path[plen - 1] == `/` {
		plen--
	}
	mut m := Match{}
	mut mask := u16(0)
	for i in 0 .. r.routes.len {
		bit := u16(1) << int(r.routes[i].method)
		if mask & bit == 0 && match_segs(r.routes[i].segs, path, plen, mut m) {
			mask |= bit
		}
	}
	if mask & (u16(1) << int(http1.Method.get)) != 0 {
		mask |= u16(1) << int(http1.Method.head)
	}
	return mask
}

fn (r &Router) find_method(method http1.Method, path string, plen int, mut m Match) int {
	clean := is_clean(path, plen)
	if clean {
		key := unsafe { tos(path.str, plen) }
		// not `if x := m[key]`: that form allocates on a miss in V 0.5.2
		if key in r.statics[int(method)] {
			m.n = 0
			return r.statics[int(method)][key]
		}
	}
	// static routes beat dynamic ones for every path spelling: the map covered clean
	// paths, so only an unclean path needs the static scan.
	if !clean {
		for i in 0 .. r.routes.len {
			if r.routes[i].method == method && r.routes[i].static
				&& match_segs(r.routes[i].segs, path, plen, mut m) {
				return i
			}
		}
	}
	for i in 0 .. r.routes.len {
		if r.routes[i].method == method && !r.routes[i].static
			&& match_segs(r.routes[i].segs, path, plen, mut m) {
			return i
		}
	}
	return -1
}

// is_clean is true when path[..plen] is already in key form: '/a/b', no empty segment.
fn is_clean(path string, plen int) bool {
	if plen == 0 || path[0] != `/` {
		return false
	}
	for k in 1 .. plen {
		if path[k] == `/` && path[k - 1] == `/` {
			return false
		}
	}
	return true
}

fn match_segs(segs []Seg, path string, plen int, mut m Match) bool {
	m.n = 0
	mut i := 0
	for s in segs {
		for i < plen && path[i] == `/` {
			i++
		}
		if s.kind == .wild {
			m.spans[m.n] = http1.Span{
				start: i
				len:   plen - i
			}
			m.n++
			return true
		}
		if i >= plen {
			return false
		}
		st := i
		for i < plen && path[i] != `/` {
			i++
		}
		if s.kind == .param {
			m.spans[m.n] = http1.Span{
				start: st
				len:   i - st
			}
			m.n++
		} else if !eq_at(path, st, i - st, s.text) {
			return false
		}
	}
	for i < plen && path[i] == `/` {
		i++
	}
	return i == plen
}

fn eq_at(path string, st int, n int, lit string) bool {
	if n != lit.len {
		return false
	}
	for k in 0 .. n {
		if path[st + k] != lit[k] {
			return false
		}
	}
	return true
}
