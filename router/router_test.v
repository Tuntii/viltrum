module router

import viltrum.http

fn test_wildcard_and_param() {
	mut r := Router.new()
	mut hit := ''
	r.get('/files/*path', fn [hit] (req http.Request) http.Response {
		// capture via headers hack - just return path param in body
		p := req.param('path') or { '' }
		return http.Response.text(200, p)
	})
	// rebuild with mutable approach
	r = Router.new()
	r.get('/files/*path', fn (req http.Request) http.Response {
		p := req.param('path') or { '' }
		return http.Response.text(200, p)
	})
	r.get('/u/:id', fn (req http.Request) http.Response {
		return http.Response.text(200, req.param('id') or { '' })
	})
	req := http.parse_request('GET /files/a/b/c HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	resp := r.handle(req)
	assert resp.body.bytestr() == 'a/b/c'
	req2 := http.parse_request('GET /u/9 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	assert r.handle(req2).body.bytestr() == '9'
}

fn test_head_falls_back_to_get() {
	mut r := Router.new()
	r.get('/hi', fn (req http.Request) http.Response {
		return http.Response.text(200, 'hello')
	})
	req := http.parse_request('HEAD /hi HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	resp := r.handle(req)
	assert resp.status == 200
	assert resp.body.bytestr() == 'hello' // handler may set body; engine strips on wire
	assert resp.headers.get('content-length')? == '5'
}

fn test_patch_route() {
	mut r := Router.new()
	r.patch('/x', fn (req http.Request) http.Response {
		return http.Response.text(200, 'patched')
	})
	req := http.parse_request('PATCH /x HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	assert r.handle(req).body.bytestr() == 'patched'
}
