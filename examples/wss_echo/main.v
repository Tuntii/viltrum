module main

// WebSocket echo over TLS (wss://).
//
//   bash scripts/dev-cert.sh
//   v run examples/wss_echo
//   websocat -k wss://127.0.0.1:8444/ws

import os
import viltrum {
	new
	text
	Request
	Response
	ServerOptions
	TlsOptions
	WsSocket
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
	app.server_options(ServerOptions{
		handle_signals: true
	})

	app.get('/', fn (req Request) Response {
		return text(200, 'wss_echo: connect wss://127.0.0.1:8444/ws\n')
	})

	app.ws('/ws', fn (mut s WsSocket) {
		for {
			msg := s.read_message() or { break }
			if msg.is_text() {
				s.write_text(msg.text()) or { break }
			} else if msg.is_binary() {
				s.write_binary(msg.data) or { break }
			}
		}
		s.close_quiet()
	})

	addr := '127.0.0.1:8444'
	println('wss_echo on https://${addr}/  wss://${addr}/ws')
	println('  cert=${cert} key=${key}')
	app.listen_tls(addr, TlsOptions{
		cert_file: cert
		key_file:  key
	}) or { panic(err) }
}
