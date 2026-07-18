module main

// Hello Viltrum — minimal API server.

import viltrum

fn hello(_req viltrum.Request) viltrum.Response {
	return viltrum.text(200, 'hello from viltrum\n')
}

fn greet(req viltrum.Request) viltrum.Response {
	name := viltrum.param(req, 'name') or { 'world' }
	// tiny hand-rolled JSON (no dependency) — framework stays lean
	body := '{"message":"hello, ${name}"}'
	return viltrum.json(200, body)
}

fn health(_req viltrum.Request) viltrum.Response {
	return viltrum.json(200, '{"status":"ok"}')
}

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.logger)
	app.get('/', hello)
	app.get('/health', health)
	app.get('/hi/:name', greet)

	addr := '127.0.0.1:8080'
	println('Viltrum example → http://${addr}')
	println('  GET /')
	println('  GET /health')
	println('  GET /hi/:name')
	app.listen(addr) or { panic(err) }
}
