module http

import time

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
	assert normalize_path('/a/') == '/a'
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
		assert err.msg().len > 0
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

// --- parse fuzz / edge cases (v0.3.1) ---

fn test_fuzz_incomplete_headers() {
	parse_request('GET / HTTP/1.1\r\nHost: x\r\n'.bytes()) or {
		assert true
		return
	}
	assert false
}

fn test_fuzz_bad_version() {
	parse_request('GET / HTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert err.msg().contains('version') || err.msg().len > 0
		return
	}
	assert false
}

fn test_fuzz_empty_header_name() {
	parse_request('GET / HTTP/1.1\r\nHost: x\r\n: nope\r\n\r\n'.bytes()) or {
		assert true
		return
	}
	assert false
}

fn test_fuzz_negative_content_length() {
	parse_request('POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -3\r\n\r\n'.bytes()) or {
		assert true
		return
	}
	assert false
}

fn test_fuzz_incomplete_body() {
	parse_request('POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nshort'.bytes()) or {
		assert err.msg().contains('incomplete') || err.msg().len > 0
		return
	}
	assert false
}

fn test_fuzz_zero_content_length() {
	req := parse_request('POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	assert req.body.len == 0
}

fn test_fuzz_crlf_only_body_separator() {
	// absolute bare minimum GET
	req := parse_request('GET / HTTP/1.1\r\nHost: a\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	assert req.path == '/'
}

fn test_fuzz_tab_in_header_value() {
	req := parse_request('GET / HTTP/1.1\r\nHost: x\r\nX-A: hello\tworld\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	assert req.headers.get('x-a')? == 'hello\tworld'
}

fn test_fuzz_url_decode_truncated() {
	url_decode('a%2') or {
		assert true
		return
	}
	assert false
}

fn test_fuzz_url_decode_bad_hex() {
	url_decode('a%zz') or {
		assert true
		return
	}
	assert false
}

fn test_http10_should_close_default() {
	req := parse_request('GET / HTTP/1.0\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	resp := Response.text(200, 'ok')
	assert should_close(req, resp) == true
}

fn test_json_string_int_bool() {
	raw := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 45\r\n\r\n{"title":"hi","n":42,"ok":true}'.bytes()
	// fix content-length
	body := '{"title":"hi","n":42,"ok":true}'
	msg := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	req := parse_request(msg.bytes()) or {
		assert false, err.msg()
		return
	}
	assert req.json_string('title')? == 'hi'
	assert req.json_int('n')? == 42
	assert req.json_bool('ok')? == true
}

// --- v0.3.x correctness ---

fn test_reject_transfer_encoding_chunked() {
	raw := 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n'.bytes()
	parse_request(raw) or {
		assert err.msg().contains('transfer-encoding')
		return
	}
	assert false, 'expected transfer-encoding rejection'
}

fn test_reject_transfer_encoding_and_content_length_conflict() {
	raw := 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello'.bytes()
	parse_request(raw) or {
		assert err.msg().contains('conflict')
		return
	}
	assert false, 'expected TE+CL conflict'
}

fn test_reject_transfer_encoding_gzip() {
	// TE without CL
	raw := 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n'.bytes()
	parse_request(raw) or {
		assert err.msg().contains('transfer-encoding')
		return
	}
	assert false, 'expected transfer-encoding rejection'
}

fn test_switching_protocols_bytes() {
	r := Response.switching_protocols('websocket')
	s := r.to_bytes().bytestr()
	assert s.starts_with('HTTP/1.1 101 Switching Protocols')
	assert s.contains('Connection: Upgrade')
	assert s.contains('Upgrade: websocket')
	assert !s.contains('Content-Length')
}

fn test_http_date_shape() {
	t := time.unix(1579099200) // 2020-01-15 …
	d := http_date(t)
	assert d.ends_with(' GMT')
	assert d.contains('2020')
	assert d.contains('Jan')
	assert d.count(',') == 1
	parts := d.split(' ')
	assert parts.len == 6 // ddd, DD MMM YYYY HH:mm:ss GMT
	assert parts[0].ends_with(',')
}

fn test_status_503_reason() {
	r := Response.text(503, 'busy')
	assert r.reason == 'Service Unavailable'
	assert r.to_bytes().bytestr().contains('503 Service Unavailable')
}

fn test_head_omits_body_keeps_content_length() {
	r := Response.text(200, 'hello')
	s := r.to_bytes_for_method('HEAD').bytestr()
	assert s.contains('Content-Length: 5')
	assert s.contains('HTTP/1.1 200 OK')
	assert !s.ends_with('hello')
	// body after headers must be empty
	sep := s.index('\r\n\r\n') or {
		assert false
		return
	}
	assert s[sep + 4..].len == 0
}

fn test_get_still_includes_body() {
	r := Response.text(200, 'hello')
	s := r.to_bytes_for_method('GET').bytestr()
	assert s.ends_with('hello')
}

fn test_absolute_form_target() {
	raw := 'GET http://example.com/api/hi?x=1 HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.path == '/api/hi'
	assert req.query == 'x=1'
	assert req.query_param('x')? == '1'
}

fn test_absolute_form_root_no_path() {
	raw := 'GET http://example.com HTTP/1.1\r\nHost: example.com\r\n\r\n'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.path == '/'
}

fn test_options_asterisk_form() {
	raw := 'OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	req := parse_request(raw) or {
		assert false, err.msg()
		return
	}
	assert req.method == 'OPTIONS'
	assert req.path == '*'
	assert req.target == '*'
}
