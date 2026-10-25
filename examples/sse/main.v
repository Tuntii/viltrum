module main

import time
import viltrum

// Server-Sent Events and streamed bodies. Open http://127.0.0.1:8085/ in two browser
// tabs: each gets a clock tick every second from a timer on its own stream, and what
// one tab says reaches every tab through the chat topic, on whichever worker it is.
// /export.csv is a 100000-row body generated as the client takes it.

const page = '<!doctype html>
<meta charset="utf-8">
<title>viltrum SSE</title>
<p>clock: <span id="clock">…</span></p>
<form id="say"><input name="m" autocomplete="off" placeholder="say something"> <button>send</button></form>
<ul id="log"></ul>
<script>
const es = new EventSource("/events")
es.addEventListener("clock", e => { clock.textContent = e.data })
es.addEventListener("chat", e => {
	const li = document.createElement("li")
	li.textContent = e.data
	log.prepend(li)
})
say.onsubmit = e => {
	e.preventDefault()
	fetch("/say", { method: "POST", body: say.m.value })
	say.m.value = ""
}
</script>
'

fn clock(mut s viltrum.Stream, _ u64) {
	s.event('clock', time.now().hhmmss())
	s.after(1000, clock, 0)
}

const events = &viltrum.StreamHandler{
	on_open:   fn (mut s viltrum.Stream, mut c viltrum.Ctx) {
		s.retry(2000)
		s.subscribe('chat')
		clock(mut s, 0)
	}
	heartbeat: 15 * time.second
}

const rows = 100000

// export writes ten rows each time the last ones are out; s.data counts the rows sent
const export = &viltrum.StreamHandler{
	on_open:  fn (mut s viltrum.Stream, mut c viltrum.Ctx) {
		s.write_string('id,square\n')
	}
	on_drain: fn (mut s viltrum.Stream) {
		mut n := int(u64(s.data))
		if n >= rows {
			s.end()
			return
		}
		for _ in 0 .. 10 {
			s.write_string('${n},${i64(n) * n}\n')
			n++
		}
		s.data = voidptr(u64(n))
	}
}

fn main() {
	mut app := viltrum.new()
	app.get('/', fn (mut c viltrum.Ctx) {
		c.bytes(200, 'text/html; charset=utf-8', page.bytes())
	})
	app.get('/events', fn (mut c viltrum.Ctx) {
		c.sse(events)
	})
	// any handler, or any thread, can publish to a topic's streams
	app.post('/say', fn [app] (mut c viltrum.Ctx) {
		msg := c.body().bytestr().trim_space()
		if msg.len > 0 {
			app.publish_event('chat', 'chat', msg)
		}
		c.no_content(204)
	})
	app.get('/export.csv', fn (mut c viltrum.Ctx) {
		c.set_header('Content-Disposition', 'attachment; filename="export.csv"')
		c.stream(200, 'text/csv', export)
	})
	app.listen('127.0.0.1:8085') or { panic(err) }
}
