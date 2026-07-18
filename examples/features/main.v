module main

// Demo: mount + mount middleware + cors + static + wildcard.

import os
import viltrum

fn ping(_req viltrum.Request) viltrum.Response {
	return viltrum.json(200, '{"pong":true}')
}

fn hi(req viltrum.Request) viltrum.Response {
	name := req.param('name') or { 'world' }
	return viltrum.json(200, '{"hi":"${name}"}')
}

fn echo_title(req viltrum.Request) viltrum.Response {
	title := req.json_string('title') or {
		return viltrum.text(400, 'need {"title":"..."}')
	}
	return viltrum.json(200, '{"title":"${title}"}')
}

fn catch_all(req viltrum.Request) viltrum.Response {
	rest := req.param('path') or { '' }
	return viltrum.json(200, '{"rest":"${rest}"}')
}

fn main() {
	// Prefer compiled-in source dir; fallback to cwd/public for odd launchers.
	mut dir := os.join_path(os.dir(@FILE), 'public')
	if !os.is_dir(dir) {
		dir = os.abs_path('public')
	}
	os.mkdir_all(dir) or {}
	os.write_file(os.join_path(dir, 'index.html'), '<h1>viltrum static</h1>\n') or {}
	os.write_file(os.join_path(dir, 'hello.txt'), 'hello from disk\n') or {}

	mut app := viltrum.new()
	// Interactive Ctrl+C shutdown works with default handle_signals=true.
	app.use(viltrum.recover)
	app.use(viltrum.cors('*'))
	app.use(viltrum.static_files('/static', dir))
	app.use(viltrum.logger)

	app.get('/health', fn (_ viltrum.Request) viltrum.Response {
		return viltrum.json(200, '{"status":"ok"}')
	})

	// route-level middleware via chain
	app.get('/chain', viltrum.chain([viltrum.logger], fn (_ viltrum.Request) viltrum.Response {
		return viltrum.text(200, 'chained\n')
	}))

	app.mount('/api', fn (mut m viltrum.Mount) {
		m.use(fn (next viltrum.Handler) viltrum.Handler {
			return fn [next] (req viltrum.Request) viltrum.Response {
				mut resp := next(req)
				resp.headers.set('X-Mount', 'api')
				return resp
			}
		})
		m.get('/ping', ping)
		m.get('/hi/:name', hi)
		m.post('/echo', echo_title)
	})

	// wildcard: /w/a/b/c -> rest=a/b/c
	app.get('/w/*path', catch_all)

	addr := '127.0.0.1:8082'
	println('Viltrum features -> http://${addr}')
	println('  GET  /health')
	println('  GET  /api/ping  (X-Mount header)')
	println('  GET  /api/hi/:name')
	println('  POST /api/echo  {"title":"..."}')
	println('  GET  /w/*path')
	println('  GET  /static/hello.txt')
	app.listen(addr) or { panic(err) }
}
