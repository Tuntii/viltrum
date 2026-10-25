module main

import viltrum

// Streams through the public API: an SSE route with its timers slept out by
// handle_raw, behind gzip, which leaves a stream alone.

fn countdown(mut s viltrum.Stream, n u64) {
	if n == 0 {
		s.event('done', '')
		s.end()
		return
	}
	s.event_id('${n}', '', 'n=${n}')
	s.after(1, countdown, n - 1)
}

fn countdown_open(mut s viltrum.Stream, mut c viltrum.Ctx) {
	s.retry(2000)
	if id := c.header('last-event-id') {
		s.comment('resumed after ${id}')
	}
	s.after(1, countdown, u64(c.query_int('from') or { 2 }))
}

const countdown_h = &viltrum.StreamHandler{
	on_open: countdown_open
}

fn events(mut c viltrum.Ctx) {
	c.sse(countdown_h)
}

fn test_sse_through_the_app() {
	mut a := viltrum.new()
	a.get('/events', viltrum.gzip, events)
	r := a.handle_raw('GET /events?from=2 HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nLast-Event-ID: 5\r\n\r\n') or {
		panic(err)
	}
	head := r.all_before('\r\n\r\n')
	assert head.contains('Content-Type: text/event-stream\r\n')
		&& !head.contains('Content-Encoding')
	mut body := []string{}
	mut rest := r.all_after('\r\n\r\n')
	// undo the chunk framing
	for rest.len > 0 {
		n := ('0x' + rest.all_before('\r\n')).int()
		rest = rest.all_after('\r\n')
		if n == 0 {
			break
		}
		body << rest[..n]
		rest = rest[n + 2..]
	}
	assert body == ['retry: 2000\n\n', ': resumed after 5\n\n', 'id: 2\ndata: n=2\n\n',
		'id: 1\ndata: n=1\n\n', 'event: done\ndata: \n\n']
}
