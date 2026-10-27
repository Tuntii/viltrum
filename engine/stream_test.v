module engine

import time
import viltrum.http1
import viltrum.router

// Streaming responses on the worker, driven through process and process_waiting like
// the HTTP/1.1 tests: requests in through c.rbuf, the stream out of c.wbuf.

struct Counter {
mut:
	opened int
	closed int
}

const counts = &Counter{}

fn count_open() {
	mut k := unsafe { counts }
	k.opened++
}

fn count_close(mut s http1.Stream) {
	mut k := unsafe { counts }
	k.closed++
}

// tick sends an event, arg more times, then ends the stream
fn sse_tick(mut s http1.Stream, arg u64) {
	if arg == 0 {
		s.end()
		return
	}
	s.event('tick', 'x')
	s.after(1, sse_tick, arg - 1)
}

fn sse_open(mut s http1.Stream, mut c http1.Ctx) {
	count_open()
	s.event_id('1', 'hello', c.path())
	s.after(5, sse_tick, u64(c.query_int('n') or { 2 }))
}

const sse_h = &http1.StreamHandler{
	on_open:  sse_open
	on_close: count_close
}

// gen writes a chunk each time the last one is out, five in all
fn gen_drain(mut s http1.Stream) {
	n := u64(s.data)
	if n == 5 {
		s.end()
		return
	}
	s.write_string('chunk')
	s.data = voidptr(n + 1)
}

const gen_h = &http1.StreamHandler{
	on_drain: gen_drain
	on_close: count_close
}

fn sub_open(mut s http1.Stream, mut c http1.Ctx) {
	s.subscribe('news')
}

const sub_h = &http1.StreamHandler{
	on_open:   sub_open
	on_close:  count_close
	heartbeat: 15 * time.second
}

fn h_sse(mut c http1.Ctx) {
	c.sse(sse_h)
}

fn h_gen(mut c http1.Ctx) {
	c.stream(200, 'text/plain', gen_h)
}

fn h_sub(mut c http1.Ctx) {
	c.sse(sub_h)
}

fn h_plain(mut c http1.Ctx) {
	c.text(200, 'after')
}

fn stream_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/sse', [http1.Handler(h_sse)]) or { panic(err) }
	r.add(.get, '/gen', [http1.Handler(h_gen)]) or { panic(err) }
	r.add(.get, '/sub', [http1.Handler(h_sub)]) or { panic(err) }
	r.add(.get, '/p', [http1.Handler(h_plain)]) or { panic(err) }
	return r
}

fn stream_worker(opts Options) &Worker {
	return new_worker(stream_router(), Options{
		...opts
		send_date: false
	}, 0)
}

fn run(mut w Worker, req string) &Conn {
	mut c := new_conn()
	c.rbuf << req.bytes()
	w.process_waiting(mut c)
	return c
}

fn body_after_head(c &Conn) string {
	s := c.wbuf.bytestr()
	return s[s.index('\r\n\r\n') or { panic(s) } + 4..]
}

// An SSE stream: its events as on_open and its timers write them, chunked, then the
// request pipelined behind it.
fn test_sse_stream_then_pipelined_request() {
	mut w := stream_worker(Options{})
	closed := counts.closed
	c := run(mut w, 'GET /sse?n=2 HTTP/1.1\r\nHost: x\r\n\r\nGET /p HTTP/1.1\r\nHost: x\r\n\r\n')
	s := c.wbuf.bytestr()
	assert s.starts_with('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n'), s
	assert s.contains('Transfer-Encoding: chunked\r\n')
	assert body_after_head(c).starts_with('1f\r\nid: 1\nevent: hello\ndata: /sse\n\n\r\n' +
		'15\r\nevent: tick\ndata: x\n\n\r\n'.repeat(2) + '0\r\n\r\nHTTP/1.1 200 OK\r\n')
	assert s.ends_with('\r\n\r\nafter')
	assert counts.closed == closed + 1 && isnil(c.st) && !c.close_after && c.rbuf.len == 0
}

// A body generated as the client takes it: on_drain runs each time the output is out.
fn test_stream_generated_on_drain() {
	mut w := stream_worker(Options{})
	c := run(mut w, 'GET /gen HTTP/1.1\r\nHost: x\r\n\r\n')
	assert body_after_head(c) == '5\r\nchunk\r\n'.repeat(5) + '0\r\n\r\n'
	assert !c.close_after
	// HTTP/1.0 has no chunks: the body is the bytes, and the connection closes after
	d := run(mut w, 'GET /gen HTTP/1.0\r\n\r\n')
	assert body_after_head(d) == 'chunk'.repeat(5) && d.close_after
	assert !d.wbuf.bytestr().contains('Transfer-Encoding')
}

// Connection: close waits for the end of the stream, then applies.
fn test_stream_with_connection_close() {
	mut w := stream_worker(Options{})
	mut c := new_conn()
	c.rbuf << 'GET /sse?n=1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'.bytes()
	w.process(mut c)
	assert !isnil(c.st) && !c.close_after && !c.reading
	for !isnil(c.st) {
		w.st_run_inline(mut c)
	}
	assert c.close_after && c.wbuf.bytestr().ends_with('0\r\n\r\n')
	w.timers = Timers{}
}

// open_sub is a connection on fd 3 whose stream is subscribed to news.
fn open_sub(mut w Worker) (&Conn, []&Conn) {
	mut c := new_conn()
	c.reset(3)
	c.rbuf << 'GET /sub HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	w.process(mut c)
	assert !isnil(c.st) && c.subs.len == 1
	unsafe {
		c.wbuf.len = 0
	}
	return c, [unsafe { &Conn(nil) }, unsafe { nil }, unsafe { nil }, c]
}

// Bytes sent to one stream and published to a topic reach it as chunks; what is for
// another stream, or for the topic's WebSocket subscribers, does not.
fn test_send_and_publish_reach_the_stream() {
	mut w := stream_worker(Options{})
	mut c, mut conns := open_sub(mut w)
	me := http1.StreamId{
		worker: 0
		fd:     3
		gen:    c.gen
		stream: c.st_serial
	}
	mut touched := []&Conn{}
	w.deliver(http1.stream_post('', me, http1.StreamId{}, c'one', 3), mut conns, mut touched)
	w.deliver(http1.stream_post('news', http1.StreamId{}, http1.StreamId{}, c'two', 3), mut conns, mut
		touched)
	w.deliver(http1.sse_post('news', http1.StreamId{}, http1.StreamId{}, '', 'e', 'three') or {
		panic('sse_post')
	}, mut conns, mut touched)
	stale := http1.StreamId{
		...me
		stream: me.stream + 1
	}
	w.deliver(http1.stream_post('', stale, http1.StreamId{}, c'no', 2), mut conns, mut touched)
	w.deliver(http1.ws_post('news', http1.WsId{}, http1.WsId{}, http1.ws_text, c'ws', 2), mut
		conns, mut touched)
	assert c.wbuf.bytestr() == '3\r\none\r\n3\r\ntwo\r\n16\r\nevent: e\ndata: three\n\n\r\n'
	assert touched.len == 1 && c.touched
	// the stream that ends leaves its topics
	w.st_end(mut c)
	assert c.subs.len == 0 && w.topics.len == 0 && isnil(c.st)
}

// A client that lets four times max_pending pile up unread is closed.
fn test_slow_stream_is_closed() {
	mut w := stream_worker(Options{ max_pending: 1000 })
	mut c, mut conns := open_sub(mut w)
	mut touched := []&Conn{}
	big := []u8{len: 1500}
	for _ in 0 .. 3 {
		w.deliver(http1.stream_post('news', http1.StreamId{}, http1.StreamId{}, big.data, big.len), mut
			conns, mut touched)
	}
	assert !c.close_after
	w.deliver(http1.stream_post('news', http1.StreamId{}, http1.StreamId{}, big.data, big.len), mut
		conns, mut touched)
	assert c.close_after
}

// A quiet SSE stream gets a comment once its handler's heartbeat passes.
fn test_heartbeat() {
	mut w := stream_worker(Options{})
	mut c, _ := open_sub(mut w)
	assert !w.st_heartbeat(mut c, c.st_last + 14000)
	assert w.st_heartbeat(mut c, c.st_last + 15000)
	assert c.wbuf.bytestr() == '4\r\n: \n\n\r\n'
	assert !w.st_heartbeat(mut c, c.st_last + 1000) // the comment counts as output
}

fn alloc_tick(mut s http1.Stream, arg u64) {
	s.event('tick', 'x')
	s.after(1, alloc_tick, arg)
}

// The zero-allocation gate, for streams: once warm, a timer's event and a send to the
// stream allocate nothing.
fn test_stream_allocates_nothing() {
	mut w := stream_worker(Options{})
	mut c, mut conns := open_sub(mut w)
	me := http1.StreamId{
		fd:     3
		gen:    c.gen
		stream: c.st_serial
	}
	post := http1.stream_post('', me, http1.StreamId{}, c'data: x\n\n', 9)
	mut touched := []&Conn{}
	w.timers.push_tick(0, 3, c.gen, c.st_serial, alloc_tick, 0)
	mut before := u64(0)
	for k in 0 .. 6000 {
		if k == 1000 {
			before = http1.allocated_bytes()
		}
		t := w.timers.pop()
		assert w.st_tick(mut c, t.stream, t.cb(), t.arg)
		w.deliver(post, mut conns, mut touched)
		touched.clear()
		c.touched = false
		unsafe {
			c.wbuf.len = 0
		}
	}
	assert http1.allocated_bytes() - before == 0
}
