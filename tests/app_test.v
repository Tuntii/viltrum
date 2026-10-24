module main

import time
import viltrum

fn hello(mut c viltrum.Ctx) {
	c.text(200, 'hello')
}

fn user(mut c viltrum.Ctx) {
	c.text(200, c.param('id') or { '' })
}

fn tag(mut c viltrum.Ctx) {
	c.set_header('X-Tag', 'g')
	c.next()
}

fn redirect(mut c viltrum.Ctx) {
	c.set_header('Location', c.query_param('next') or { '/' })
	c.no_content(302)
}

fn silent(mut c viltrum.Ctx) {}

fn big(mut c viltrum.Ctx) {
	c.text(200, 'z'.repeat(1000))
}

fn waited(mut c viltrum.Ctx, ms u64) {
	c.set_header('X-Waited', 'yes')
	c.text(200, 'waited ${ms}')
}

fn wait(mut c viltrum.Ctx) {
	ms := c.param_int('ms') or { 0 }
	c.after(int(ms), waited, u64(ms))
}

fn build_app() &viltrum.App {
	mut a := viltrum.new()
	a.use(viltrum.cors('*'))
	a.get('/', hello)
	mut api := a.group('/api', tag)
	api.get('/users/:id', user)
	a.get('/r', redirect)
	a.get('/silent', viltrum.recover, silent)
	a.get('/big', viltrum.gzip, big)
	a.get('/wait/:ms', viltrum.recover, wait)
	return a
}

fn test_routes_groups_and_global_middleware() {
	a := build_app()
	r1 := a.handle_raw('GET / HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r1.contains('Access-Control-Allow-Origin: *\r\n') && r1.ends_with('hello')
	r2 := a.handle_raw('GET /api/users/7 HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r2.contains('X-Tag: g\r\n') && r2.ends_with('\r\n\r\n7')
	r3 := a.handle_raw('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r3.starts_with('HTTP/1.1 404 ') && r3.contains('Access-Control-Allow-Origin')
	r4 := a.handle_raw('OPTIONS /api/users/7 HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r4.starts_with('HTTP/1.1 204 ') && r4.contains('Access-Control-Allow-Methods')
	r5 := a.handle_raw('GET /silent HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r5.starts_with('HTTP/1.1 500 ') && r5.contains('Connection: close\r\n')
	r6 := a.handle_raw('GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n')!
	assert r6.contains('Content-Encoding: gzip\r\n')
}

fn test_header_injection_is_dropped() {
	a := build_app()
	r := a.handle_raw('GET /r?next=%2Fa%0d%0aSet-Cookie:%20x=1 HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r.starts_with('HTTP/1.1 302 ') && !r.contains('Set-Cookie') && !r.contains('Location')
	r2 := a.handle_raw('GET /r?next=%2Fok HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert r2.contains('Location: /ok\r\n')
}

fn test_bad_pattern_is_reported() {
	mut a := viltrum.new()
	a.get('/x/*rest/y', hello)
	a.handle_raw('GET / HTTP/1.1\r\nHost: x\r\n\r\n') or {
		assert err.msg().contains('wildcard')
		return
	}
	assert false, 'bad pattern accepted'
}

// recover leaves a deferred response alone, and handle_raw waits it out.
fn test_deferred_response() {
	app := build_app()
	// the monotonic clock: time.ticks moves in ~16 ms steps on Windows
	t0 := time.sys_mono_now()
	res := app.handle_raw('GET /wait/30 HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	assert time.sys_mono_now() - t0 >= 30_000_000
	assert res.starts_with('HTTP/1.1 200 OK\r\n') && res.contains('X-Waited: yes\r\n')
	assert res.ends_with('waited 30') && !res.contains('Connection: close')
}

fn need_token(mut c viltrum.Ctx) {
	if (c.query_param('token') or { '' }) != 'k' {
		c.text(401, 'no token')
		return
	}
	c.next()
}

const ws_up = 'Host: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'

// masked is a one-frame client text message with an all-zero mask.
fn masked(s string) string {
	return [u8(0x81), u8(0x80 | s.len), 0, 0, 0, 0].bytestr() + s
}

fn test_websocket_route_with_middleware() {
	mut a := viltrum.new()
	a.use(viltrum.cors('*'))
	mut api := a.group('/api', tag)
	api.ws('/chat/:room', viltrum.WsHandler{
		on_open:    fn (mut s viltrum.Ws, mut c viltrum.Ctx) {
			s.send_text('joined ' + (c.param('room') or { '' }))
		}
		on_message: fn (mut s viltrum.Ws, m viltrum.WsMessage) {
			s.send_text(m.text().to_upper())
		}
	}, need_token)
	r := a.handle_raw('GET /api/chat/blue?token=k HTTP/1.1\r\n' + ws_up + masked('hey'))!
	assert r.starts_with('HTTP/1.1 101 Switching Protocols\r\n')
	assert r.contains('X-Tag: g\r\n') && r.contains('Access-Control-Allow-Origin: *\r\n')
	assert r.contains('Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n')
	assert r.ends_with('\r\n\r\n\x81\x0bjoined blue\x81\x03HEY')
	refused := a.handle_raw('GET /api/chat/blue HTTP/1.1\r\n' + ws_up + masked('hey'))!
	assert refused.starts_with('HTTP/1.1 401 ') && !refused.contains('\x81')
	plain := a.handle_raw('GET /api/chat/blue?token=k HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert plain.starts_with('HTTP/1.1 426 ') && plain.contains('Upgrade: websocket\r\n')
}

// gzip middleware in front of a WebSocket route leaves the 101 alone.
fn test_websocket_behind_gzip() {
	mut a := viltrum.new()
	a.use(viltrum.gzip)
	a.ws('/ws', viltrum.WsHandler{
		on_message: fn (mut s viltrum.Ws, m viltrum.WsMessage) {
			s.send_text(m.text())
		}
	})
	r := a.handle_raw('GET /ws HTTP/1.1\r\nAccept-Encoding: gzip\r\n' + ws_up +
		masked('x'.repeat(100)))!
	assert r.starts_with('HTTP/1.1 101 ') && r.count('HTTP/1.1') == 1
	assert !r.contains('Content-Encoding') && r.ends_with('x'.repeat(100))
}

fn upload(mut c viltrum.Ctx) {
	f := c.form_file('doc') or {
		c.text(400, 'no file')
		return
	}
	note := c.form_value('note') or { '' }
	name := f.safe_filename() or { '' }
	c.text(200, '${note}|${name}|${f.content_type}|${f.data.bytestr()}')
}

fn test_form_upload_through_the_app() {
	mut a := viltrum.new()
	a.post('/up', upload)
	body := '--b\r\nContent-Disposition: form-data; name="note"\r\n\r\nhi there\r\n--b\r\nContent-Disposition: form-data; name="doc"; filename="../x.txt"\r\nContent-Type: text/plain\r\n\r\nfile\r\nbody\r\n--b--\r\n'
	r :=
		a.handle_raw('POST /up HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: ${body.len}\r\n\r\n${body}')!
	assert r.starts_with('HTTP/1.1 200 ')
		&& r.ends_with('\r\n\r\nhi there|x.txt|text/plain|file\r\nbody')
	r2 :=
		a.handle_raw('POST /up HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 6\r\n\r\ndoc=no')!
	assert r2.starts_with('HTTP/1.1 400 ')
}

// publish and ws_send need a running server; without one they are dropped quietly.
fn test_publish_without_a_server_is_dropped() {
	mut a := viltrum.new()
	a.ws('/room', viltrum.WsHandler{
		on_message: fn (mut s viltrum.Ws, m viltrum.WsMessage) {
			s.subscribe('r')
			s.publish('r', m.text())
			s.send_text('ok')
		}
	})
	a.publish('r', 'nobody hears this')
	a.ws_send(viltrum.WsId{}, 'nor this')
	r := a.handle_raw('GET /room HTTP/1.1\r\n' + ws_up + masked('hi'))!
	assert r.starts_with('HTTP/1.1 101 ') && r.ends_with('\x81\x02ok')
}

fn dx_page(mut c viltrum.Ctx) {
	visits := (c.cookie('visits') or { '0' }).int()
	c.set_cookie(name: 'visits', value: '${visits + 1}', max_age: 60)
	c.html(200, '<b>${c.method_name()}</b>')
}

fn dx_done(mut c viltrum.Ctx) {
	c.redirect(303, '/page')
}

// The handler conveniences through a real app, and 405s that say what is allowed,
// with and without global middleware (the two ways a 405 is answered).
fn test_dx_helpers_and_allow_on_405() {
	for global in [false, true] {
		mut a := viltrum.new()
		if global {
			a.use(viltrum.recover)
		}
		a.get('/page', dx_page)
		a.post('/page', dx_done)
		mut g := a.group('/g')
		g.head('/h', hello)
		g.options('/h', hello)
		r1 := a.handle_raw('GET /page HTTP/1.1\r\nHost: x\r\nCookie: visits=41\r\n\r\n')!
		assert r1.contains('Content-Type: text/html; charset=utf-8\r\n')
		assert r1.contains('Set-Cookie: visits=42; Path=/; Max-Age=60; HttpOnly; SameSite=Lax\r\n')
		assert r1.ends_with('<b>GET</b>')
		r2 := a.handle_raw('POST /page HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n')!
		assert r2.starts_with('HTTP/1.1 303 ') && r2.contains('Location: /page\r\n')
		r3 := a.handle_raw('DELETE /page HTTP/1.1\r\nHost: x\r\n\r\n')!
		assert r3.starts_with('HTTP/1.1 405 '), 'global=${global}'
		assert r3.contains('\r\nAllow: GET, HEAD, POST\r\n'), 'global=${global}'
		r4 := a.handle_raw('OPTIONS /g/h HTTP/1.1\r\nHost: x\r\n\r\n')!
		assert r4.starts_with('HTTP/1.1 200 ')
		r5 := a.handle_raw('GET /g/h HTTP/1.1\r\nHost: x\r\n\r\n')!
		assert r5.contains('\r\nAllow: HEAD, OPTIONS\r\n'), 'global=${global}'
	}
}
