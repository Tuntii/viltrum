module main

// First-party WebSocket echo (cleartext ws://).
//
//   v run examples/ws_echo
//   websocat ws://127.0.0.1:8084/ws

import viltrum {
	new
	text
	Request
	Response
	ServerOptions
	WsSocket
}

fn main() {
	mut app := new()
	app.server_options(ServerOptions{
		handle_signals: true
	})

	app.get('/', fn (req Request) Response {
		return text(200, 'ws_echo: connect ws://127.0.0.1:8084/ws\n')
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

	println('ws_echo on http://127.0.0.1:8084/  ws://127.0.0.1:8084/ws')
	app.listen('127.0.0.1:8084') or { panic(err) }
}
