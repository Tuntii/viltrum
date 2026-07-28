module main

// Minimal HTTPS server (self-signed).
//
//   bash scripts/dev-cert.sh
//   v run examples/https_hello
//   curl -k https://127.0.0.1:8443/

import os
import viltrum {
	new
	recover
	logger
	text
	json
	Request
	Response
	TlsOptions
}

fn main() {
	cert := os.getenv_opt('VILTRUM_CERT') or { 'certs/dev.crt' }
	key := os.getenv_opt('VILTRUM_KEY') or { 'certs/dev.key' }
	if !os.exists(cert) || !os.exists(key) {
		eprintln('missing ${cert} / ${key}')
		eprintln('run: bash scripts/dev-cert.sh')
		exit(1)
	}

	mut app := new()
	app.use(recover)
	app.use(logger)

	app.get('/', fn (_req Request) Response {
		return text(200, 'hello over https\n')
	})
	app.get('/health', fn (_req Request) Response {
		return json(200, '{"status":"ok","tls":true}')
	})

	addr := '127.0.0.1:8443'
	println('Viltrum https_hello → https://${addr}')
	println('  cert=${cert} key=${key}')
	println('  curl -k https://${addr}/')
	app.listen_tls(addr, TlsOptions{
		cert_file: cert
		key_file:  key
	}) or { panic(err) }
}
