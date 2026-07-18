module http

fn test_parse_get() {
	raw := 'GET /hi/tunay?x=1 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: test\r\n\r\n'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.method == 'GET'
	assert req.path == '/hi/tunay'
	assert req.query == 'x=1'
	assert req.headers.get('host')? == 'localhost'
}

fn test_parse_post_body() {
	raw := 'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.method == 'POST'
	assert req.body.bytestr() == 'hello'
}

fn test_response_bytes_contain_status() {
	r := Response.text(200, 'ok')
	s := r.to_bytes().bytestr()
	assert s.starts_with('HTTP/1.1 200 OK')
	assert s.contains('Content-Length: 2')
	assert s.ends_with('ok')
}
