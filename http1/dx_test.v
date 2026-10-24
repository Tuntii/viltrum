module http1

fn dx_out(c Ctx) string {
	return c.out.bytestr()
}

fn get_with(headers string) !Ctx {
	return test_ctx('GET /p HTTP/1.1\r\nHost: h\r\n${headers}\r\n')!
}

fn test_method_names() {
	assert Method.get.name() == 'GET'
	assert Method.options.name() == 'OPTIONS'
	assert Method.other.name() == 'OTHER'
	c := test_ctx('PROPFIND /p HTTP/1.1\r\nHost: h\r\n\r\n')!
	assert c.method() == .other
	assert c.method_name() == 'PROPFIND'
	assert get_with('')!.method_name() == 'GET'
}

fn test_body_text_is_a_view() {
	c := test_ctx('POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 13\r\n\r\n{"name":"Ad"}')!
	assert c.body_text() == '{"name":"Ad"}'
	assert c.body_text().str == unsafe { &u8(c.body_bytes.data) }
	assert get_with('')!.body_text() == ''
}

fn test_html() {
	mut c := get_with('')!
	c.html(200, '<p>hi</p>')
	assert dx_out(c) == 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 9\r\n\r\n<p>hi</p>'
}

fn test_redirect() {
	mut c := get_with('')!
	c.redirect(303, '/items?flash=saved')
	assert dx_out(c) == 'HTTP/1.1 303 See Other\r\nContent-Length: 0\r\nLocation: /items?flash=saved\r\n\r\n'
	// a Location that would split the response is dropped, the redirect still answers
	mut bad := get_with('')!
	bad.redirect(302, '/x\r\nSet-Cookie: a=b')
	assert !dx_out(bad).contains('Set-Cookie') && dx_out(bad).starts_with('HTTP/1.1 302 ')
}

fn test_cookie_reads_every_cookie_header() {
	c := get_with('Cookie: theme=dark; session=abc123 ;  empty=\r\nCookie: q="quoted v"; flag\r\n')!
	assert c.cookie('theme')? == 'dark'
	assert c.cookie('session')? == 'abc123'
	assert c.cookie('empty')? == ''
	assert c.cookie('q')? == 'quoted v'
	assert c.cookie('flag')? == ''
	for miss in ['sess', 'session2', 'Theme', 'dark'] {
		if v := c.cookie(miss) {
			assert false, '${miss} -> ${v}'
		}
	}
	if _ := get_with('')!.cookie('a') {
		assert false
	}
}

fn test_set_cookie_defaults_are_the_safe_ones() {
	mut c := get_with('')!
	c.set_cookie(name: 'session', value: 'vt_1')
	c.no_content(204)
	assert dx_out(c).contains('\r\nSet-Cookie: session=vt_1; Path=/; HttpOnly; SameSite=Lax\r\n')
}

fn test_set_cookie_attributes() {
	mut c := get_with('')!
	c.set_cookie(
		name:      'pref'
		value:     'a-b'
		path:      '/app'
		domain:    'example.com'
		max_age:   3600
		secure:    true
		http_only: false
		same_site: .strict
	)
	c.set_cookie(name: 'embed', value: '1', same_site: .cross_site)
	c.set_cookie(name: 'plain', value: '1', same_site: .unset, path: '')
	c.clear_cookie(name: 'session')
	c.no_content(204)
	out := dx_out(c)
	assert out.contains('\r\nSet-Cookie: pref=a-b; Path=/app; Domain=example.com; Max-Age=3600; Secure; SameSite=Strict\r\n')
	// SameSite=None only works with Secure, so it always carries it
	assert out.contains('\r\nSet-Cookie: embed=1; Path=/; Secure; HttpOnly; SameSite=None\r\n')
	assert out.contains('\r\nSet-Cookie: plain=1; HttpOnly\r\n')
	assert out.contains('\r\nSet-Cookie: session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax\r\n')
}

fn test_invalid_cookies_are_dropped() {
	mut c := get_with('')!
	c.set_cookie(name: 'a b', value: '1')
	c.set_cookie(name: 'a', value: 'x;y')
	c.set_cookie(name: 'a', value: 'x y')
	c.set_cookie(name: 'a', value: '1', path: '/;Domain=evil')
	c.set_cookie(name: 'a', value: '1', domain: 'x\r\ny')
	c.set_cookie(name: 'big', value: 'v'.repeat(600)) // over the in-place buffer
	c.set_cookie(name: 'ok', value: '1')
	c.no_content(204)
	out := dx_out(c)
	assert out.count('Set-Cookie') == 1 && out.contains('Set-Cookie: ok=1;')
}

fn test_header_buffer_is_reused_across_requests() {
	mut c := get_with('')!
	for i in 0 .. 3 {
		buf := 'GET /p HTTP/1.1\r\nHost: h\r\n\r\n'.bytes()
		c.begin(view(buf, 0, buf.len))
		unsafe {
			c.out.len = 0
		}
		c.set_cookie(name: 'n', value: '${i}')
		c.set_cookie(name: 'm', value: 'x${i}')
		c.no_content(204)
		out := dx_out(c)
		assert out.contains('Set-Cookie: n=${i};') && out.contains('Set-Cookie: m=x${i};')
		assert c.nhval < 100 // started over, did not pile up
	}
}

fn test_set_allow() {
	mut c := test_ctx('DELETE /p HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.allow = u16(1) << int(Method.get) | u16(1) << int(Method.head) | u16(1) << int(Method.post)
	c.set_allow()
	c.text(405, 'method not allowed')
	assert dx_out(c).contains('\r\nAllow: GET, HEAD, POST\r\n')
	mut none_set := test_ctx('DELETE /p HTTP/1.1\r\nHost: h\r\n\r\n')!
	none_set.set_allow()
	none_set.text(405, 'x')
	assert !dx_out(none_set).contains('\r\nAllow:')
}

fn test_helpers_allocate_nothing() {
	mut c := get_with('Cookie: theme=dark; session=abc123\r\n')!
	for _ in 0 .. 100 {
		run_helpers(mut c)
	}
	before := allocated_bytes()
	for _ in 0 .. 10000 {
		run_helpers(mut c)
	}
	assert allocated_bytes() - before == 0
}

fn run_helpers(mut c Ctx) {
	c.responded = false
	c.nextra = 0
	unsafe {
		c.out.len = 0
	}
	assert (c.cookie('session') or { '' }).len == 6
	assert c.method_name().len == 3
	assert c.body_text().len == 0
	c.set_cookie(name: 'session', value: 'abc123', max_age: 604800)
	c.allow = 7
	c.set_allow()
	c.redirect(303, '/items')
	assert c.out.len > 100
}
