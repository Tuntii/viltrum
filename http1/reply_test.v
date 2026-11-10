module http1

fn reply_of(s string, head bool, eof bool) !(int, ReplyFrame, []u8) {
	buf := s.bytes()
	mut f := ReplyFrame{}
	n := frame_reply(buf, mut f, head, eof, 1024 * 1024)!
	return n, f, buf
}

fn test_reply_with_length() {
	s := 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello'
	n, f, buf := reply_of(s, false, false)!
	assert n == s.len
	assert f.status == 200
	assert f.keep
	assert reply_body(buf, &f, n).bytestr() == 'hello'
	assert reply_header(view(buf, 0, f.head_end), 'content-type')? == 'text/plain'
	assert reply_header(view(buf, 0, f.head_end), 'CONTENT-LENGTH')? == '5'
	assert reply_header(view(buf, 0, f.head_end), 'x-none') == none
	// a byte short is not whole yet; the same bytes after the upstream closed are cut short
	m, _, _ := reply_of(s[..s.len - 1], false, false)!
	assert m == -1
	reply_of(s[..s.len - 1], false, true) or {
		assert err.code() == 503
		return
	}
	assert false
}

fn test_reply_chunked_byte_by_byte() {
	s := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7;x=y\r\n, world\r\n0\r\nX-T: 1\r\n\r\n'
	all := s.bytes()
	mut f := ReplyFrame{}
	mut n := -1
	for i in 1 .. all.len + 1 {
		n = frame_reply(all[..i], mut f, false, false, 1024)!
		if i < all.len {
			assert n == -1, '${i}'
		}
	}
	assert n == all.len
	assert reply_body(all, &f, n).bytestr() == 'hello, world'
}

fn test_reply_until_close() {
	s := 'HTTP/1.1 200 OK\r\n\r\nall of it'
	n, f, _ := reply_of(s, false, false)!
	assert n == -1
	assert f.until_close && !f.keep
	m, g, buf := reply_of(s, false, true)!
	assert m == s.len
	assert reply_body(buf, &g, m).bytestr() == 'all of it'
}

fn test_reply_without_body() {
	for s in ['HTTP/1.1 204 No Content\r\n\r\n',
		'HTTP/1.1 304 Not Modified\r\nContent-Length: 9\r\n\r\n'] {
		n, f, _ := reply_of(s, false, false)!
		assert n == s.len
		assert f.keep
	}
	s := 'HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n'
	n, _, _ := reply_of(s, true, false)!
	assert n == s.len
}

fn test_reply_interim_head() {
	s := 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
	n, f, _ := reply_of(s, false, false)!
	assert f.interim
	assert n == 'HTTP/1.1 100 Continue\r\n\r\n'.len
	m, g, buf := reply_of(s[n..], false, false)!
	assert g.status == 200
	assert reply_body(buf, &g, m).bytestr() == 'ok'
}

fn test_reply_keep_alive_rules() {
	cases := {
		'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n':      false
		'HTTP/1.1 200 OK\r\nConnection: x, Close\r\nContent-Length: 0\r\n\r\n':   false
		'HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n':                           false
		'HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n': true
		'HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n': true
	}
	for s, keep in cases {
		_, f, _ := reply_of(s, false, false)!
		assert f.keep == keep, s
	}
}

fn test_reply_refused() {
	cases := {
		'HTTP/2 200 OK\r\n\r\n':                                                                        502
		'HTTP/1.1 2x0 OK\r\n\r\n':                                                                      502
		'HTTP/1.1 200OK\r\n\r\n':                                                                       502
		'HTTP/1.1 101 Switching\r\n\r\n':                                                               502
		'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n':                   502
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n':                                           502
		'HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n':                                                502
		// a bare LF or CR, or a NUL, in the head: a handler could copy it into its response
		'HTTP/1.1 200 OK\r\nContent-Type: a\nSet-Cookie: x\r\n\r\n':                                    502
		'HTTP/1.1 200 OK\r\nContent-Type: a\rb\r\n\r\n':                                                502
		'HTTP/1.1 200 OK\r\nX: a\x00b\r\n\r\n':                                                         502
		'HTTP/1.1 200 OK\r\nContent-Length: 2000000\r\n\r\n':                                           413
		'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab':                          502
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n': 502
		'HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n':                                           413
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n':                                  502
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n200000\r\n${'x'.repeat(8)}':              413
	}
	for s, code in cases {
		reply_of(s, false, false) or {
			assert err.code() == code, s
			continue
		}
		assert false, s
	}
}

fn test_write_fetch() {
	mut c := Ctx.new()
	c.begin(view(c.buf, 0, 0))
	c.fetch(Upstream{ id: 0 }, .post, '/users?x=1', unsafe { nil }, 7)
	c.fetch_body('{"a":1}'.bytes())
	c.fetch_header('Content-Type', 'application/json')
	c.fetch_header('Bad', 'a\r\nInjected: 1') // dropped
	assert c.fetch_valid()
	mut out := []u8{}
	c.write_fetch(mut out, 'api:9000')
	assert out.bytestr() == 'POST /users?x=1 HTTP/1.1\r\nHost: api:9000\r\nContent-Length: 7\r\nContent-Type: application/json\r\n\r\n{"a":1}'
	assert c.deferred && c.defer_arg == 7
	// a target that would split the request line, or a method fetch cannot name
	for t in ['/a b', '/a\r\nX: 1', '/\x00'] {
		c.begin(view(c.buf, 0, 0))
		c.fetch(Upstream{ id: 0 }, .get, t, unsafe { nil }, 0)
		assert !c.fetch_valid(), t
	}
	c.begin(view(c.buf, 0, 0))
	c.fetch(Upstream{ id: 0 }, .get, '', unsafe { nil }, 0)
	unsafe {
		out.len = 0
	}
	c.write_fetch(mut out, 'h')
	assert out.bytestr() == 'GET / HTTP/1.1\r\nHost: h\r\n\r\n'
}

fn test_reply_allocates_nothing() {
	s := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: b\r\n\r\n5\r\nhello\r\n0\r\n\r\n'
	src := s.bytes()
	mut buf := []u8{len: src.len}
	mut f := ReplyFrame{}
	mut before := u64(0)
	for i in 0 .. 3 {
		if i == 1 {
			before = allocated_bytes()
		}
		// reply_body decoded the last round's chunks in place: start over
		unsafe { C.memcpy(buf.data, src.data, src.len) }
		f.reset()
		n := frame_reply(buf, mut f, false, false, 1024) or { panic(err) }
		assert reply_body(buf, &f, n).len == 5
		assert reply_header(view(buf, 0, f.head_end), 'x-a') or { '' } == 'b'
	}
	assert allocated_bytes() - before == 0
}
