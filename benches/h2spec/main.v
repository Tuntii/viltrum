module main

import os
import viltrum

// The server h2spec (HTTP/2 conformance) runs against: HTTP/2 beside HTTP/1.1, in
// cleartext on 9002 and over TLS on 9003 (the engine's test certificate), as
// docs/http2.md describes. See run.sh.
fn main() {
	mut app := viltrum.new()
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'ok')
	})
	app.post('/', fn (mut c viltrum.Ctx) {
		c.bytes(200, 'application/octet-stream', c.body())
	})
	certs := os.join_path(os.dir(@FILE), '..', '..', 'engine', 'testdata', 'tls')
	app.serve([
		viltrum.Listener{
			addr:  '127.0.0.1:9002'
			http2: true
		},
		viltrum.Listener{
			addr:  '127.0.0.1:9003'
			http2: true
			tls:   viltrum.TlsOptions{
				cert_file: os.join_path(certs, 'a.crt')
				key_file:  os.join_path(certs, 'a.key')
			}
		},
	]) or { panic(err) }
}
