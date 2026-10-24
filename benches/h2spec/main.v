module main

import viltrum

// The server h2spec (HTTP/2 conformance) runs against: one cleartext listener with
// HTTP/2 beside HTTP/1.1, as docs/http2.md describes. See run.sh.
fn main() {
	mut app := viltrum.new()
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'ok')
	})
	app.post('/', fn (mut c viltrum.Ctx) {
		c.bytes(200, 'application/octet-stream', c.body())
	})
	app.serve([
		viltrum.Listener{
			addr:  '127.0.0.1:9002'
			http2: true
		},
	]) or { panic(err) }
}
