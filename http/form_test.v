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

fn multipart_req(body string, boundary string) Request {
	msg := 'POST /up HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=${boundary}\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	return parse_request(msg.bytes()) or { panic(err) }
}

fn test_multipart_too_many_parts() {
	boundary := '----Lim'
	mut body := ''
	for i in 0 .. 65 {
		body += '--${boundary}\r\nContent-Disposition: form-data; name="f${i}"\r\n\r\nx\r\n'
	}
	body += '--${boundary}--\r\n'
	req := multipart_req(body, boundary)
	req.form_parts() or {
		assert err.msg().contains('too many parts')
		assert err.msg().contains('64')
		return
	}
	assert false, '65 parts should exceed default max_parts'
}

fn test_multipart_part_too_large() {
	boundary := '----Big'
	payload := 'y'.repeat(8)
	body := '--${boundary}\r\nContent-Disposition: form-data; name="f"\r\n\r\n${payload}\r\n--${boundary}--\r\n'
	req := multipart_req(body, boundary)
	req.form_parts_opts(FormOptions{
		max_parts:      8
		max_part_bytes: 4
	}) or {
		assert err.msg().contains('part too large')
		return
	}
	assert false, 'part over max_part_bytes should error'
}

fn test_form_parts_opts_allows_custom_max() {
	boundary := '----N'
	body := '--${boundary}\r\nContent-Disposition: form-data; name="a"\r\n\r\n1\r\n--${boundary}\r\nContent-Disposition: form-data; name="b"\r\n\r\n2\r\n--${boundary}--\r\n'
	req := multipart_req(body, boundary)
	parts := req.form_parts_opts(FormOptions{
		max_parts:      2
		max_part_bytes: 16
	}) or {
		assert false, err.msg()
		return
	}
	assert parts.len == 2
}

fn test_safe_filename_strips_path() {
	assert FormPart{
		filename: 'a/b.txt'
	}.safe_filename()? == 'b.txt'
	assert FormPart{
		filename: r'C:\foo\bar.txt'
	}.safe_filename()? == 'bar.txt'
	assert FormPart{
		filename: 'plain.txt'
	}.safe_filename()? == 'plain.txt'
}

fn test_safe_filename_rejects_dotdot_and_empty() {
	if _ := FormPart{
		filename: '..'
	}.safe_filename() {
		assert false, '.. must be rejected'
	}
	if _ := FormPart{
		filename: 'foo/..'
	}.safe_filename() {
		assert false, 'basename .. must be rejected'
	}
	if _ := FormPart{
		filename: '.'
	}.safe_filename() {
		assert false, '. must be rejected'
	}
	if _ := FormPart{
		filename: ''
	}.safe_filename() {
		assert false, 'empty must be rejected'
	}
	if _ := FormPart{
		filename: 'x\0y.txt'
	}.safe_filename() {
		assert false, 'NUL must be rejected'
	}
	// path stripped first, leftover is a real name
	assert FormPart{
		filename: '../x.txt'
	}.safe_filename()? == 'x.txt'
}
