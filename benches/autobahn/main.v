module main

import viltrum

// The echo server the Autobahn|Testsuite fuzzing client runs against (see
// benches/AUTOBAHN.md). Every message comes back as it came; max_message is raised
// past the suite's largest message (16 MiB, cases 9.*).
fn main() {
	mut app := viltrum.new()
	app.ws('/', viltrum.WsHandler{
		max_message: 32 * 1024 * 1024
		on_message:  fn (mut s viltrum.Ws, m viltrum.WsMessage) {
			if m.binary {
				s.send_binary(m.data)
			} else {
				s.send_text(m.text())
			}
		}
	})
	app.listen('127.0.0.1:9001') or { panic(err) }
}
