module http

fn test_form_urlencoded_value() {
	body := 'title=hello+world&empty=&x=1'
	msg := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	req := parse_request(msg.bytes()) or {
		assert false, err.msg()
		return
	}
	assert req.form_value('title')? == 'hello world'
	assert req.form_value('empty')? == ''
	assert req.form_value('x')? == '1'
	if _ := req.form_value('missing') {
		assert false
	}
}

fn test_multipart_text_and_file() {
	boundary := '----ViltrumTest'
	body := '--${boundary}\r\nContent-Disposition: form-data; name="title"\r\n\r\nhello\r\n--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\nContent-Type: text/plain\r\n\r\nfile-bytes\r\n--${boundary}--\r\n'
	msg := 'POST /up HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=${boundary}\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	req := parse_request(msg.bytes()) or {
		assert false, err.msg()
		return
	}
	assert req.form_value('title')? == 'hello'
	f := req.form_file('file') or {
		assert false, 'missing file'
		return
	}
	assert f.filename == 'a.txt'
	assert f.content_type == 'text/plain'
	assert f.data.bytestr() == 'file-bytes'
	parts := req.form_parts() or {
		assert false, err.msg()
		return
	}
	assert parts.len == 2
}

fn test_multipart_quoted_boundary() {
	body := '------B\r\nContent-Disposition: form-data; name="n"\r\n\r\nv\r\n------B--\r\n'
	// Content-Type boundary="----B"
	ct := 'multipart/form-data; boundary="----B"'
	msg := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Type: ${ct}\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	req := parse_request(msg.bytes()) or {
		assert false, err.msg()
		return
	}
	assert req.form_value('n')? == 'v'
}

fn test_form_parts_rejects_non_multipart() {
	msg := 'POST / HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nhi'
	req := parse_request(msg.bytes()) or {
		assert false
		return
	}
	req.form_parts() or {
		assert err.msg().contains('not multipart')
		return
	}
	assert false
}
