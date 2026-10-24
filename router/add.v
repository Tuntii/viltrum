module router

import viltrum.http1

// Route registration: cold, it runs before the server starts.

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
	// the later of two routes with one shape could never match
	for rt in r.routes {
		if rt.method == method && same_shape(rt.segs, segs) {
			return error('router: duplicate route ${method.name()} ${pattern} (already ${rt.pattern})')
		}
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
		r.statics[int(method)]['/' + segs.map(it.text).join('/')] = idx
	}
}

// same_shape is true when a and b match the same paths: equal literals, params and
// wildcards in the same places, whatever they are named.
fn same_shape(a []Seg, b []Seg) bool {
	if a.len != b.len {
		return false
	}
	for i in 0 .. a.len {
		if a[i].kind != b[i].kind || (a[i].kind == .lit && a[i].text != b[i].text) {
			return false
		}
	}
	return true
}
