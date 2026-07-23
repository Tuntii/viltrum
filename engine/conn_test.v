module engine

import viltrum.http

fn test_conn_pushback_drains_before_socket() {
	mut c := Conn.new_buffered('LEFT'.bytes())
	assert c.buffered_len() == 4
	mut buf := []u8{len: 4}
	c.read_exact(mut buf) or {
		assert false, err.msg()
		return
	}
	assert buf.bytestr() == 'LEFT'
	assert c.buffered_len() == 0
	// further read has no socket / empty pushback → error
	mut more := []u8{len: 1}
	c.read(mut more) or {
		assert true
		return
	}
	assert false, 'expected read error after pushback drained'
}

fn test_conn_pushback_partial_reads() {
	mut c := Conn.new_buffered('abcdef'.bytes())
	mut a := []u8{len: 2}
	n := c.read(mut a) or {
		assert false
		return
	}
	assert n == 2
	assert a.bytestr() == 'ab'
	assert c.buffered_len() == 4
	mut b := []u8{len: 4}
	c.read_exact(mut b) or {
		assert false
		return
	}
	assert b.bytestr() == 'cdef'
}

fn test_match_parts_param_and_wildcard() {
	params, ok := match_parts(['echo'], ['echo'])
	assert ok
	assert params.len == 0

	params2, ok2 := match_parts(['room', ':id'], ['room', '7'])
	assert ok2
	assert params2['id'] == '7'

	params3, ok3 := match_parts(['files', '*path'], ['files', 'a', 'b'])
	assert ok3
	assert params3['path'] == 'a/b'
}

fn test_match_upgrade_method_and_path() {
	mut called := false
	routes := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/echo'
			handler: fn (mut c Conn, req http.Request) {
			}
		},
	]
	// build a minimal request via parse
	req := http.parse_request('GET /echo HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	hit := match_upgrade(routes, req) or {
		assert false, 'expected upgrade match'
		return
	}
	assert hit.params.len == 0
	_ = called
}

fn test_match_upgrade_param() {
	routes := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/u/:id'
			handler: fn (mut c Conn, req http.Request) {
			}
		},
	]
	req := http.parse_request('GET /u/42 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	hit := match_upgrade(routes, req) or {
		assert false
		return
	}
	assert hit.params['id'] == '42'
}

fn test_match_upgrade_wrong_method() {
	routes := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/echo'
			handler: fn (mut c Conn, req http.Request) {
			}
		},
	]
	req := http.parse_request('POST /echo HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	match_upgrade(routes, req) or {
		assert true
		return
	}
	assert false, 'POST should not match GET upgrade'
}

// --- header pre-scan (byte-level CL / TE; no full stringification) ---

fn test_content_length_byte_scan() {
	hdr := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5'.bytes()
	cl := content_length_from_headers(hdr) or {
		assert false, 'expected Content-Length'
		return
	}
	assert cl == 5
}

fn test_content_length_case_insensitive_and_ows() {
	hdr := 'POST / HTTP/1.1\r\nHost: x\r\ncOnTeNt-LeNgTh:  \t12\t '.bytes()
	cl := content_length_from_headers(hdr) or {
		assert false, 'expected Content-Length'
		return
	}
	assert cl == 12
}

fn test_content_length_absent() {
	hdr := 'GET / HTTP/1.1\r\nHost: x'.bytes()
	content_length_from_headers(hdr) or {
		assert true
		return
	}
	assert false, 'expected no Content-Length'
}

fn test_content_length_negative() {
	hdr := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -3'.bytes()
	cl := content_length_from_headers(hdr) or {
		assert false
		return
	}
	assert cl == -3
}

fn test_content_length_skips_request_line() {
	// Path must not be scanned as a header field.
	hdr := 'GET /Content-Length:%205 HTTP/1.1\r\nHost: x'.bytes()
	content_length_from_headers(hdr) or {
		assert true
		return
	}
	assert false, 'request-line must not yield Content-Length'
}

fn test_transfer_encoding_byte_scan() {
	hdr := 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked'.bytes()
	assert transfer_encoding_present(hdr) == true
}

fn test_transfer_encoding_case_insensitive() {
	hdr := 'POST / HTTP/1.1\r\nHost: x\r\ntRaNsFeR-eNcOdInG: gzip'.bytes()
	assert transfer_encoding_present(hdr) == true
}

fn test_transfer_encoding_empty_value_not_present() {
	hdr := 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding:   '.bytes()
	assert transfer_encoding_present(hdr) == false
}

fn test_transfer_encoding_absent() {
	hdr := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0'.bytes()
	assert transfer_encoding_present(hdr) == false
}

fn test_te_and_cl_both_detected_for_conflict_path() {
	// Engine rejects TE+CL when both pre-scans fire; keep that contract.
	hdr := 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5'.bytes()
	assert transfer_encoding_present(hdr) == true
	cl := content_length_from_headers(hdr) or {
		assert false, 'expected Content-Length beside TE'
		return
	}
	assert cl == 5
}

fn test_header_value_ci_first_match_wins() {
	hdr := 'POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 99'.bytes()
	cl := content_length_from_headers(hdr) or {
		assert false
		return
	}
	assert cl == 1
}
