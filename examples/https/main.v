module main

import viltrum

// Cleartext on 8080 and HTTPS on 8443 from the same workers. Make a dev certificate
// first: bash scripts/dev-cert.sh (writes certs/dev.crt and certs/dev.key).
fn main() {
	mut app := viltrum.new()
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'Hello over TLS or not\n')
	})
	app.serve([
		viltrum.Listener{
			addr: '127.0.0.1:8080'
		},
		viltrum.Listener{
			addr: '127.0.0.1:8443'
			tls:  viltrum.TlsOptions{
				cert_file: 'certs/dev.crt'
				key_file:  'certs/dev.key'
			}
		},
	]) or { panic(err) }
}
