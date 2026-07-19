module main

// Hello Viltrum — minimal API server.

import viltrum {
	new
	recover
	logger
	text
	json
	Request
	Response
}

fn hello(_req Request) Response {
	return text(200, 'hello from viltrum\n')
}

fn greet(req Request) Response {
	name := req.param('name') or { 'world' }
	body := '{"message":"hello, ${name}"}'
	return json(200, body)
}

fn health(_req Request) Response {
	return json(200, '{"status":"ok"}')
}

fn main() {
	mut app := new()
	app.use(recover)
	app.use(logger)
	app.get('/', hello)
	app.get('/health', health)
	app.get('/hi/:name', greet)

	addr := '127.0.0.1:8080'
	println('Viltrum hello → http://${addr}')
	println('  GET /')
	println('  GET /health')
	println('  GET /hi/:name')
	app.listen(addr) or { panic(err) }
}
