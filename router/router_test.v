module router

import viltrum.http1

fn h(mut c http1.Ctx) {}

fn chain() []http1.Handler {
	return [http1.Handler(h)]
}

fn build() &Router {
	mut r := &Router{}
	for p in ['/', '/a/b', '/u/:id', '/u/:id/posts/:post', '/files/*rest', 'nolead'] {
		r.add(.get, p, chain()) or { panic(err) }
	}
	r.add(.post, '/a/b', chain()) or { panic(err) }
	return r
}

fn lookup(r &Router, method http1.Method, path string) (int, []string) {
	mut m := Match{}
	idx := r.find(method, path, mut m)
	mut vals := []string{}
	if idx >= 0 {
		for k in 0 .. m.n {
			s := m.spans[k]
			vals << path[s.start..s.start + s.len]
		}
	}
	return idx, vals
}

fn test_matching() {
	r := build()
	cases := {
		'/':             0
		'/a/b':          1
		'/a/b/':         1
		'/a//b':         1
		'//a/b':         1
		'/nolead':       5
		'/u/42':         2
		'/u/42/':        2
		'/u/42/posts/7': 3
		'/files':        4
		'/files/a/b/c':  4
		'/u':            not_found
		'/missing':      not_found
		'/u/42/posts':   not_found
		'/a/b/c':        not_found
	}
	for path, want in cases {
		idx, _ := lookup(r, .get, path)
		assert idx == want, path
	}
	_, v1 := lookup(r, .get, '/u/42/posts/7')
	assert v1 == ['42', '7']
	_, v2 := lookup(r, .get, '/files/a//b/')
	assert v2 == ['a//b']
	_, v3 := lookup(r, .get, '/files/')
	assert v3 == ['']
}

fn test_methods() {
	r := build()
	post, _ := lookup(r, .post, '/a/b')
	assert post == 6
	put, _ := lookup(r, .put, '/a/b')
	assert put == method_not_allowed
	head, _ := lookup(r, .head, '/u/9')
	assert head == 2
	miss, _ := lookup(r, .put, '/nope')
	assert miss == not_found
}

fn test_bad_patterns() {
	mut r := &Router{}
	for p in ['/x/*rest/y', '/x/:', '/x/*', '/:a/:b/:c/:d/:e/:f/:g/:h/:i'] {
		r.add(.get, p, chain()) or { continue }
		assert false, 'accepted ${p}'
	}
}

fn test_find_allocates_nothing() {
	r := build()
	mut m := Match{}
	paths := ['/a/b', '/a//b', '/u/42/posts/7', '/files/x/y', '/missing']
	before := http1.allocated_bytes()
	for _ in 0 .. 10000 {
		for p in paths {
			_ = r.find(.get, p, mut m)
		}
		_ = r.find(.put, '/a/b', mut m)
	}
	assert http1.allocated_bytes() - before == 0
}

fn test_static_beats_dynamic() {
	mut r := &Router{}
	r.add(.get, '/u/:id', chain()) or { panic(err) }
	r.add(.get, '/u/me', chain()) or { panic(err) }
	for p in ['/u/me', '/u/me/', '/u//me'] {
		idx, _ := lookup(r, .get, p)
		assert idx == 1, p
	}
	idx, _ := lookup(r, .get, '/u/7')
	assert idx == 0
}

fn test_duplicate_routes_are_refused() {
	mut r := build()
	for p in ['/a/b', '/a/b/', '//a/b', '/u/:user', '/files/*path'] {
		if _ := r.add(.get, p, chain()) {
			assert false, 'accepted a second GET ' + p
		}
	}
	r.add(.get, '/u/:id/x', chain()) or { panic(err) } // a different shape
	r.add(.put, '/a/b', chain()) or { panic(err) } // a different method
	idx, _ := lookup(r, .get, '/a/b')
	assert idx == 1
}
