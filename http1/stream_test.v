module http1

// What Stream writes, framed or not, and the head Ctx.stream and Ctx.sse answer with.

fn raw_stream() Stream {
	return Stream{
		out: []u8{cap: 256}
	}
}

fn chunked_stream() Stream {
	return Stream{
		out:     []u8{cap: 256}
		chunked: true
	}
}

fn test_sse_event_lines() {
	cases := {
		'plain':        ['', '', 'hi', 'data: hi\n\n']
		'named':        ['', 'tick', '1', 'event: tick\ndata: 1\n\n']
		'with id':      ['7', 'tick', '1', 'id: 7\nevent: tick\ndata: 1\n\n']
		'empty data':   ['', '', '', 'data: \n\n']
		'lf':           ['', '', 'a\nb', 'data: a\ndata: b\n\n']
		'crlf':         ['', '', 'a\r\nb', 'data: a\ndata: b\n\n']
		'cr':           ['', '', 'a\rb', 'data: a\ndata: b\n\n']
		'trailing lf':  ['', '', 'a\n', 'data: a\ndata: \n\n']
		'blank inside': ['', '', 'a\n\nb', 'data: a\ndata: \ndata: b\n\n']
	}
	for name, c in cases {
		mut out := []u8{}
		n := sse_event_len(c[0], c[1], c[2])
		sse_event(mut out, c[0], c[1], c[2])
		assert out.bytestr() == c[3], name
		assert n == out.len, name
	}
	// what the client cannot be told is refused, not mangled
	assert sse_event_len('', 'a\nb', 'x') == -1
	assert sse_event_len('a\rb', '', 'x') == -1
	assert sse_event_len('a\x00b', '', 'x') == -1
}

fn test_stream_writes_raw() {
	mut s := raw_stream()
	s.write_string('ab')
	s.write([]u8{})
	s.write('cd'.bytes())
	s.event('e', 'x')
	s.comment('')
	s.retry(3000)
	s.end()
	s.write_string('dropped')
	assert s.out.bytestr() == 'abcdevent: e\ndata: x\n\n: \n\nretry: 3000\n\n'
	assert s.ended
}

fn test_stream_writes_chunked() {
	mut s := chunked_stream()
	s.write_string('hello')
	s.write_string('x'.repeat(26))
	s.event('', 'hi')
	s.comment('a\nb')
	s.end()
	s.end()
	assert s.out.bytestr() == '5\r\nhello\r\n1a\r\n${'x'.repeat(26)}\r\n' +
		'a\r\ndata: hi\n\n\r\n' + '9\r\n: a\n: b\n\n\r\n' + '0\r\n\r\n'
}

fn test_chunk_sizes_in_hex() {
	for n in [1, 9, 10, 15, 16, 255, 256, 4095, 65536, 1 << 24] {
		mut out := []u8{}
		chunk_head(mut out, n)
		assert out.bytestr() == '${n:x}\r\n', n.str()
	}
}

fn test_timers_and_topics_wait_for_the_engine() {
	mut s := raw_stream()
	s.after(10, fn (mut s Stream, arg u64) {}, 3)
	s.subscribe('news')
	s.publish('news', 'x'.bytes())
	s.publish_event('news', 'e', 'y')
	s.publish('', 'x'.bytes()) // no topic: nothing
	assert s.timers.len == 1 && s.timers[0].ms == 10 && s.timers[0].arg == 3
	assert s.subs.len == 1 && s.subs[0].on
	assert s.posts.len == 2 && s.posts[0].op == stream_data
		&& s.posts[1].data.bytestr() == 'event: e\ndata: y\n\n'
	s.end()
	s.after(10, fn (mut s Stream, arg u64) {}, 0) // ended: no more timers
	assert s.timers.len == 1
}

fn get_ctx(minor int, method Method) Ctx {
	mut c := Ctx.new()
	c.send_date = false
	c.head.method = method
	c.head.minor = minor
	c.head.keep_alive = true
	c.out = []u8{cap: 1024}
	c.begin([]u8{})
	return c
}

const events = &StreamHandler{}

fn test_stream_heads() {
	mut c := get_ctx(1, .get)
	c.sse(events)
	assert c.out.bytestr() == 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n' +
		'Cache-Control: no-cache\r\nX-Accel-Buffering: no\r\nTransfer-Encoding: chunked\r\n\r\n'
	assert voidptr(c.st) == voidptr(events) && c.st_sse && c.responded && c.wrote && !c.close_after
	// HTTP/1.0: no chunks, the connection's end is the body's
	mut d := get_ctx(0, .get)
	d.stream(200, 'text/plain', events)
	assert d.out.bytestr() == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n'
	assert !isnil(d.st) && !d.st_sse && d.close_after
	// HEAD and statuses without a body: the head alone, no stream
	mut h := get_ctx(1, .head)
	h.stream(200, 'text/plain', events)
	assert h.out.bytestr().contains('Transfer-Encoding: chunked\r\n') && isnil(h.st)
	mut n := get_ctx(1, .get)
	n.stream(204, '', events)
	assert !n.out.bytestr().contains('Transfer-Encoding') && isnil(n.st)
}
