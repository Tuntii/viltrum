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
	assert req.query_param('x')? == '1'
}

fn test_parse_post_body() {
	raw := 'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.method == 'POST'
	assert req.body.bytestr() == 'hello'
	assert req.text() == 'hello'
}

fn test_response_bytes_contain_status() {
	r := Response.text(200, 'ok')
	s := r.to_bytes().bytestr()
	assert s.starts_with('HTTP/1.1 200 OK')
	assert s.contains('Content-Length: 2')
	assert s.contains('Connection: keep-alive')
	assert s.ends_with('ok')
}

fn test_should_close_http11_default_keepalive() {
	req := parse_request('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	resp := Response.text(200, 'ok')
	assert should_close(req, resp) == false
}

fn test_should_close_when_request_says_close() {
	req := parse_request('GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	resp := Response.text(200, 'ok')
	assert should_close(req, resp) == true
}

fn test_param_on_request() {
	mut req := parse_request('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	req.params['name'] = 'tunay'
	assert req.param('name')? == 'tunay'
}

fn test_query_decode_plus_and_percent() {
	raw := 'GET /s?q=hello+world%21&n=a%20b HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.query_param('q')? == 'hello world!'
	assert req.query_param('n')? == 'a b'
}

fn test_trailing_slash_normalized() {
	raw := 'GET /todos/ HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.path == '/todos'
	assert normalize_path('/') == '/'
	assert normalize_path('/a//') == '/a' || normalize_path('/a/') == '/a'
}

fn test_duplicate_headers_combined() {
	raw := 'GET / HTTP/1.1\r\nHost: x\r\nAccept: text/html\r\nAccept: application/json\r\n\r\n'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.headers.get('accept')? == 'text/html, application/json'
}

fn test_bad_request_line() {
	parse_request('GET /\r\nHost: x\r\n\r\n'.bytes()) or {
		assert err.msg().contains('bad request') || err.msg().len > 0
		return
	}
	assert false, 'expected error'
}

fn test_empty_method() {
	parse_request(' / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert true
		return
	}
	assert false
}

fn test_response_header_builder() {
	mut r := Response.text(200, 'ok')
	r = r.header('X-Request-Id', 'abc')
	s := r.to_bytes().bytestr()
	assert s.contains('X-Request-Id: abc')
}

fn test_url_decode() {
	assert url_decode('a%2Fb')! == 'a/b'
	assert url_decode('a+b')! == 'a b'
}
