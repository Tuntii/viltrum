module main

// Demo: mount groups, CORS, static files.

import os
import viltrum

fn ping(_req viltrum.Request) viltrum.Response {
	return viltrum.json(200, '{"pong":true}')
}

fn hi(req viltrum.Request) viltrum.Response {
	name := req.param('name') or { 'world' }
	return viltrum.json(200, '{"hi":"${name}"}')
}

fn main() {
	dir := os.join_path(os.dir(@FILE), 'public')
	os.mkdir_all(dir) or {}
	os.write_file(os.join_path(dir, 'index.html'), '<h1>viltrum static</h1>\n') or {}
	os.write_file(os.join_path(dir, 'hello.txt'), 'hello from disk\n') or {}

	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.use(viltrum.cors('*'))
	app.use(viltrum.static_files('/static', dir))
	app.use(viltrum.logger)

	app.get('/health', fn (_ viltrum.Request) viltrum.Response {
		return viltrum.json(200, '{"status":"ok"}')
	})

	app.mount('/api', fn (mut m viltrum.Mount) {
		m.get('/ping', ping)
		m.get('/hi/:name', hi)
	})

	addr := '127.0.0.1:8082'
	println('Viltrum features → http://${addr}')
	println('  GET  /health')
	println('  GET  /api/ping')
	println('  GET  /api/hi/:name')
	println('  GET  /static/hello.txt')
	println('  OPTIONS /api/ping  (CORS preflight)')
	app.listen(addr) or { panic(err) }
}
