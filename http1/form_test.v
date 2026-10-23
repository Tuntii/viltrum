module http1

fn post(content_type string, body string) !Ctx {
	return test_ctx('POST /f HTTP/1.1\r\nHost: h\r\nContent-Type: ${content_type}\r\nContent-Length: ${body.len}\r\n\r\n${body}')!
}

const mp_body = 'preamble\r\n--XyZ\r\nContent-Disposition: form-data; name="title"\r\n\r\nHello, world\r\n--XyZ\r\nContent-Disposition: form-data; name="doc"; filename="C:\\docs\\a;b.txt"\r\nContent-Type: text/plain\r\n\r\nline 1\r\nline 2 --XyZ not a delimiter\r\n\r\n--XyZ\r\ncontent-disposition: FORM-DATA; filename=""; name=empty\r\n\r\n\r\n--XyZ\r\nContent-Disposition: form-data; name="n"\r\n\r\n42\r\n--XyZ--\r\nepilogue'

fn test_urlencoded_values_are_decoded() {
	mut c := post('application/x-www-form-urlencoded; charset=UTF-8',
		'a=1&name=Ada+Lovelace&e%3D=%C3%A9&flag&n=-7')!
	assert c.form_value('name')? == 'Ada Lovelace'
	assert c.form_value('e=')? == 'é'
	assert c.form_value('flag')? == ''
	assert c.form_int('n')? == -7
	assert c.form_value('a')? == '1'
	if _ := c.form_value('missing') {
		assert false
	}
	if _ := c.form_file('a') {
		assert false
	}
	// the query is not the form
	mut q :=
		test_ctx('POST /f?x=1 HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\ny=2')!
	assert q.form_value('y')? == '2'
	if _ := q.form_value('x') {
		assert false
	}
}

fn test_chunked_form_body() {
	mut c :=
		test_ctx('POST /f HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nTransfer-Encoding: chunked\r\n\r\n4\r\na=1&\r\n5\r\nb=%41\r\n0\r\n\r\n')!
	assert c.form_value('b')? == 'A'
	assert c.form_value('a')? == '1'
}

fn test_form_needs_a_form_content_type() {
	for ct in ['text/plain', 'application/x-www-form-urlencodedX', 'application/json'] {
		mut c := post(ct, 'a=1')!
		if _ := c.form_value('a') {
			assert false, ct
		}
	}
	mut c := test_ctx('POST /f HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\na=1')!
	if _ := c.form_value('a') {
		assert false
	}
	mut it := c.form_parts()
	if _ := it.next() {
		assert false
	}
	assert !it.malformed()
}

fn test_multipart_parts() {
	mut c := post('multipart/form-data; boundary=XyZ', mp_body)!
	assert c.form_value('title')? == 'Hello, world'
	assert c.form_int('n')? == 42
	if _ := c.form_value('doc') {
		assert false // a file is not a value
	}
	f := c.form_file('doc')?
	assert f.is_file()
	assert f.filename == 'C:\\docs\\a;b.txt'
	assert f.safe_filename()? == 'a;b.txt'
	assert f.content_type == 'text/plain'
	assert f.data.bytestr() == 'line 1\r\nline 2 --XyZ not a delimiter\r\n'
	e := c.form_file('empty')?
	assert e.filename == '' && e.data.len == 0
	if _ := e.safe_filename() {
		assert false
	}
	mut names := []string{}
	mut it := c.form_parts()
	for {
		p := it.next() or { break }
		names << p.name
	}
	assert names == ['title', 'doc', 'empty', 'n']
	assert !it.malformed()
}

fn test_multipart_boundary_forms() {
	// quoted boundary, no preamble, transport padding after a delimiter
	body := '--a b\r\nContent-Disposition: form-data; name=x\r\n\r\n1\r\n--a b  \r\nContent-Disposition: form-data; name="y"\r\n\r\n2\r\n--a b--'
	mut c := post('Multipart/Form-Data; charset=utf-8; boundary="a b"', body)!
	assert c.form_value('x')? == '1'
	assert c.form_value('y')? == '2'
	// a part with no headers, and one that is not form-data, are walked past
	body2 := '--b\r\n\r\nraw\r\n--b\r\nContent-Disposition: attachment; name="z"\r\n\r\nno\r\n--b\r\nContent-Disposition: form-data; name="z"\r\n\r\nyes\r\n--b--\r\n'
	mut d := post('multipart/form-data; boundary=b', body2)!
	assert d.form_value('z')? == 'yes'
	mut it := d.form_parts()
	assert it.next()?.data.bytestr() == 'yes'
}

fn test_malformed_multipart_stops() {
	cases := {
		'no boundary':       ['multipart/form-data', '--b\r\n\r\nx\r\n--b--']
		'empty boundary':    ['multipart/form-data; boundary=""', '--\r\n\r\nx\r\n----']
		'no delimiter':      ['multipart/form-data; boundary=b', 'just text']
		'unterminated part': ['multipart/form-data; boundary=b',
			'--b\r\nContent-Disposition: form-data; name="a"\r\n\r\nvalue']
		'unended headers':   ['multipart/form-data; boundary=b',
			'--b\r\nContent-Disposition: form-data; name="a"']
		'junk after delim':  ['multipart/form-data; boundary=b', '--bjunk\r\n\r\nx\r\n--b--']
	}
	for name, cs in cases {
		mut c := post(cs[0], cs[1])!
		mut it := c.form_parts()
		if _ := it.next() {
			assert false, name
		}
		assert it.malformed(), name
		if _ := c.form_value('a') {
			assert false, name
		}
	}
	// the parts before the damage are still returned
	mut c := post('multipart/form-data; boundary=b',
		'--b\r\nContent-Disposition: form-data; name="a"\r\n\r\n1\r\n--b\r\nContent-Disposition: form-data; name="b"\r\n\r\n2')!
	mut it := c.form_parts()
	assert it.next()?.name == 'a'
	if _ := it.next() {
		assert false
	}
	assert it.malformed()
}

fn test_param_parsing() {
	v := 'form-data; filename="x.txt"; name="file"'
	s := param_span(v, 'name')
	assert sub_view(v, s.start, s.len) == 'file' // not the tail of filename
	assert !param_span("form-data; filename*=UTF-8''x", 'filename').found()
	assert media_param('multipart/form-data; BOUNDARY = "q;r" ; x=1', 'boundary') == 'q;r'
	assert media_param('multipart/form-data;boundary=abc', 'boundary') == 'abc'
	assert media_param('multipart/form-data', 'boundary') == ''
	assert is_media('form-data', 'form-data')
	assert is_media('form-data ;name=a', 'form-data')
	assert !is_media('form-database', 'form-data')
}

fn test_safe_filename() {
	cases := {
		'a.txt':         'a.txt'
		'dir/sub/a.txt': 'a.txt'
		'..\\..\\x.exe': 'x.exe'
		'/etc/passwd':   'passwd'
		'..':            ''
		'a/.':           ''
		'a/':            ''
		'':              ''
		'a\x00b':        ''
	}
	for raw, want in cases {
		p := FormPart{
			filename: raw
		}
		got := p.safe_filename() or { '' }
		assert got == want, raw
	}
}

// A form is read in place: once the buffers are grown, nothing is allocated.
fn test_forms_allocate_nothing() {
	mut u := post('application/x-www-form-urlencoded', 'a=1&name=Ada+Lovelace&n=7')!
	mut m := post('multipart/form-data; boundary=XyZ', mp_body)!
	for _ in 0 .. 100 {
		run_forms(mut u, mut m)
	}
	before := allocated_bytes()
	for _ in 0 .. 10000 {
		run_forms(mut u, mut m)
	}
	assert allocated_bytes() - before == 0
}

fn run_forms(mut u Ctx, mut m Ctx) {
	unsafe {
		u.qbuf.len = 0
	}
	assert (u.form_value('name') or { '' }).len == 12
	assert (u.form_int('n') or { 0 }) == 7
	assert (m.form_value('title') or { '' }).len == 12
	f := m.form_file('doc') or { FormPart{} }
	assert (f.safe_filename() or { '' }) == 'a;b.txt'
	mut it := m.form_parts()
	mut n := 0
	for {
		if _ := it.next() {
			n++
		} else {
			break
		}
	}
	assert n == 4
}
