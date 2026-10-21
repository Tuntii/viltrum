module main

import viltrum

// Session is one connection's own state, kept in Ws.data.
struct Session {
mut:
	room     string
	messages int
}

fn main() {
	mut app := viltrum.new()
	app.ws('/ws/:room', viltrum.WsHandler{
		on_open:    fn (mut s viltrum.Ws, mut c viltrum.Ctx) {
			// request views are valid only until on_open returns: clone what you keep
			s.data = &Session{
				room: (c.param('room') or { 'lobby' }).clone()
			}
		}
		on_message: fn (mut s viltrum.Ws, m viltrum.WsMessage) {
			mut st := unsafe { &Session(s.data) }
			st.messages++
			if m.binary {
				s.send_binary(m.data)
			} else {
				s.send_text('${st.room} #${st.messages}: ${m.text()}')
			}
		}
		on_close:   fn (mut s viltrum.Ws, code int) {
			st := unsafe { &Session(s.data) }
			println('${st.room}: closed with ${code} after ${st.messages} messages')
		}
	})
	app.listen('127.0.0.1:8084') or { panic(err) }
}
