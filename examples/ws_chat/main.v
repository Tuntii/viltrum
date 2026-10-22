module main

import time
import viltrum

// Session is one connection's own state, kept in Ws.data.
struct Session {
	room string
	name string
}

fn main() {
	mut app := viltrum.new()
	// ws://127.0.0.1:8084/chat/:room?name=ada: everything a client sends goes to the
	// others in the room, on whichever worker they are.
	app.ws('/chat/:room', viltrum.WsHandler{
		on_open:    fn (mut s viltrum.Ws, mut c viltrum.Ctx) {
			// request views are valid only until on_open returns: clone what you keep
			st := &Session{
				room: (c.param('room') or { 'lobby' }).clone()
				name: (c.query_param('name') or { 'anon' }).clone()
			}
			s.data = st
			s.subscribe(st.room)
			s.publish(st.room, '${st.name} joined')
			s.send_text('welcome to ${st.room}, ${st.name}')
		}
		on_message: fn (mut s viltrum.Ws, m viltrum.WsMessage) {
			st := unsafe { &Session(s.data) }
			if !m.binary {
				s.publish(st.room, '${st.name}: ${m.text()}')
			}
		}
		on_close:   fn (mut s viltrum.Ws, code int) {
			st := unsafe { &Session(s.data) }
			s.publish(st.room, '${st.name} left')
		}
	})
	// Any thread can publish: here a clock, once a minute, to the lobby.
	spawn fn [app] () {
		for {
			time.sleep(time.minute)
			app.publish('lobby', 'clock: ${time.now().hhmm()}')
		}
	}()
	app.listen('127.0.0.1:8084') or { panic(err) }
}
