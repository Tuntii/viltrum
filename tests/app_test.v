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
	t0 := time.ticks()
	res := app.handle_raw('GET /wait/30 HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	assert time.ticks() - t0 >= 30
	assert res.starts_with('HTTP/1.1 200 OK\r\n') && res.contains('X-Waited: yes\r\n')
	assert res.ends_with('waited 30') && !res.contains('Connection: close')
}
