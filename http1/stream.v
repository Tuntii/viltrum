module http1

import time

// Streaming responses: a body written over time, after the handler has returned. The
// handler answers with c.stream (or c.sse), and the engine keeps the connection on
// the route's StreamHandler: what its callbacks write goes out as it is written,
// chunked on HTTP/1.1. What writes come from: on_open, timers the stream sets
// (Stream.after), on_drain once everything written so far is out (a body generated
// as the client takes it), and sends and publishes from any thread through the hub.
// Server-Sent Events are a stream with the text/event-stream framing helpers below.

pub type StreamOpen = fn (mut s Stream, mut c Ctx)

pub type StreamDrain = fn (mut s Stream)

pub type StreamClose = fn (mut s Stream)

pub type StreamTick = fn (mut s Stream, arg u64)

// StreamHandler is what a streaming response does; see viltrum.StreamHandler.
@[heap]
pub struct StreamHandler {
pub:
	on_open  StreamOpen  = unsafe { nil }
	on_drain StreamDrain = unsafe { nil }
	on_close StreamClose = unsafe { nil }
	// SSE only: a comment line goes out when nothing else has for this long, so proxies
	// and load balancers keep the connection; 0 sends none
	heartbeat time.Duration
}

// StreamId names one stream among all workers (Stream.id), for sending to it from
// elsewhere. It stays unique after the stream ends: sends to it are dropped.
pub struct StreamId {
pub:
	worker int
	fd     int = -1
	gen    u32
	stream u32 // which of the connection's streams
}

// stream_data is the WsPost op of bytes for streams; a topic's WebSocket subscribers
// never get them, nor its streams a WebSocket message.
pub const stream_data = u8(0x20)

// StreamTimer is an after call, carried out when the callback returns.
pub struct StreamTimer {
pub:
	ms  int
	cb  StreamTick = unsafe { nil }
	arg u64
}

// Stream is one streaming response as its callbacks see it. A worker owns a single
// Stream and points it at each stream in turn, like Ctx.
pub struct Stream {
pub mut:
	data voidptr // this stream's own state: set it in on_open, every later callback sees it
	// engine-owned
	out     []u8 // where writes go, lent for one callback
	chunked bool // HTTP/1.1 chunk framing; otherwise the bytes go as they are
	sse     bool
	ended   bool // end() was called, or the client went away: later writes are dropped
	worker  int
	h       &StreamHandler = unsafe { nil }
	me      StreamId
	posts   []&WsPost     // publish calls, carried out when the callback returns
	subs    []WsSub       // subscribe calls, applied when the callback returns
	timers  []StreamTimer // after calls, set when the callback returns
}

// write sends b as the next piece of the body. Nothing is sent for an empty b.
pub fn (mut s Stream) write(b []u8) {
	s.put(b.data, b.len)
}

pub fn (mut s Stream) write_string(t string) {
	s.put(t.str, t.len)
}

fn (mut s Stream) put(p &u8, n int) {
	if s.ended || n == 0 {
		return
	}
	if s.chunked {
		chunk_head(mut s.out, n)
	}
	unsafe { s.out.push_many(p, n) }
	if s.chunked {
		append_str(mut s.out, crlf)
	}
}

// end finishes the body. On HTTP/1.1 the connection then serves the client's next
// request; over HTTP/1.0 it closes. on_close runs once the stream is done.
pub fn (mut s Stream) end() {
	if s.ended {
		return
	}
	s.ended = true
	if s.chunked {
		append_str(mut s.out, '0\r\n\r\n')
	}
}

// after calls cb(mut s, arg) on this stream's worker no sooner than ms milliseconds
// on, unless the stream ends first. A stream may have several timers at once.
pub fn (mut s Stream) after(ms int, cb StreamTick, arg u64) {
	if s.ended {
		return
	}
	s.timers << StreamTimer{
		ms:  ms
		cb:  cb
		arg: arg
	} // cold: grows to the most timers one callback sets
}

pub fn (s &Stream) worker_id() int {
	return s.worker
}

// id names this stream for app.stream_send and app.send_event, from any thread.
pub fn (s &Stream) id() StreamId {
	return s.me
}

// subscribe adds this stream to topic: what is published to it with
// app.stream_publish or app.publish_event reaches every subscriber, on every worker.
// A stream that ends leaves its topics.
pub fn (mut s Stream) subscribe(topic string) {
	s.subs << WsSub{
		topic: topic.clone() // cold: subscriptions, not messages
		on:    true
	}
}

pub fn (mut s Stream) unsubscribe(topic string) {
	s.subs << WsSub{
		topic: topic.clone() // cold: subscriptions, not messages
	}
}

// publish writes b to every stream subscribed to topic except this one. It is copied
// once and goes out after the callback returns.
pub fn (mut s Stream) publish(topic string, b []u8) {
	if topic.len > 0 {
		s.posts << stream_post(topic, s.me, s.me, b.data, b.len)
	}
}

// publish_event is publish of one Server-Sent Event (see event).
pub fn (mut s Stream) publish_event(topic string, name string, data string) {
	if topic.len > 0 {
		if p := sse_post(topic, s.me, s.me, '', name, data) {
			s.posts << p
		}
	}
}

// stream_post copies b for other streams: to a topic, or to the one stream to when
// topic is ''.
pub fn stream_post(topic string, to StreamId, skip StreamId, p &u8, n int) &WsPost {
	mut data := []u8{len: n} // cold: a published message is copied once for all workers
	if n > 0 {
		unsafe { vmemcpy(data.data, p, n) }
	}
	return &WsPost{
		topic:       topic.clone() // cold: as above
		to:          WsId{
			worker: to.worker
			fd:     to.fd
			gen:    to.gen
		}
		stream:      to.stream
		skip:        WsId{
			worker: skip.worker
			fd:     skip.fd
			gen:    skip.gen
		}
		skip_stream: skip.stream
		op:          stream_data
		data:        data
	}
}

// sse_post is stream_post of one event; none when the event cannot be written.
pub fn sse_post(topic string, to StreamId, skip StreamId, id string, name string, data string) ?&WsPost {
	n := sse_event_len(id, name, data)
	if n < 0 {
		return none
	}
	mut b := []u8{cap: n} // cold: as in stream_post
	sse_event(mut b, id, name, data)
	return stream_post(topic, to, skip, b.data, b.len)
}

// --- Server-Sent Events (text/event-stream) ---

// event sends one event: name is its type ('' for the default, message) and data its
// data, a line per line of it. An event whose name holds CR or LF is not sent.
pub fn (mut s Stream) event(name string, data string) {
	s.event_id('', name, data)
}

// event_id is event with an id, which the client sends back as Last-Event-ID when it
// reconnects (c.header('last-event-id') in on_open). An id holding CR, LF or NUL is
// not sent, nor its event.
pub fn (mut s Stream) event_id(id string, name string, data string) {
	n := sse_event_len(id, name, data)
	if s.ended || n < 0 {
		return
	}
	if s.chunked {
		chunk_head(mut s.out, n)
	}
	sse_event(mut s.out, id, name, data)
	if s.chunked {
		append_str(mut s.out, crlf)
	}
}

// comment sends a comment, which clients ignore: a heartbeat, or padding.
pub fn (mut s Stream) comment(text string) {
	if s.ended {
		return
	}
	n := sse_lines_len(':', text) + 1
	if s.chunked {
		chunk_head(mut s.out, n)
	}
	sse_lines(mut s.out, ':', text)
	s.out << `\n`
	if s.chunked {
		append_str(mut s.out, crlf)
	}
}

// retry tells the client how long to wait before it reconnects, in milliseconds.
pub fn (mut s Stream) retry(ms int) {
	if ms < 0 {
		return
	}
	mut tmp := [32]u8{}
	unsafe {
		mut p := put_str(&tmp[0], 'retry: ')
		p = put_uint(p, u64(ms))
		p = put_str(p, '\n\n')
		s.put(&tmp[0], int(p - &tmp[0]))
	}
}

// sse_event_len is the length of the event sse_event writes, -1 when it cannot be
// written (CR or LF in name or id, NUL in id).
pub fn sse_event_len(id string, name string, data string) int {
	mut n := 0
	if id.len > 0 {
		for k in 0 .. id.len {
			b := id[k]
			if b == `\r` || b == `\n` || b == 0 {
				return -1
			}
		}
		n += 4 + id.len + 1 // "id: " id "\n"
	}
	if name.len > 0 {
		for k in 0 .. name.len {
			if name[k] == `\r` || name[k] == `\n` {
				return -1
			}
		}
		n += 7 + name.len + 1 // "event: " name "\n"
	}
	return n + sse_lines_len('data:', data) + 1
}

// sse_event writes one event: its id, its name, its data a "data:" line per line, and
// the blank line that ends it. Check sse_event_len first.
pub fn sse_event(mut out []u8, id string, name string, data string) {
	if id.len > 0 {
		append_str(mut out, 'id: ')
		append_str(mut out, id)
		out << `\n`
	}
	if name.len > 0 {
		append_str(mut out, 'event: ')
		append_str(mut out, name)
		out << `\n`
	}
	sse_lines(mut out, 'data:', data)
	out << `\n`
}

// sse_lines_len is the length sse_lines writes.
fn sse_lines_len(field string, text string) int {
	mut n := field.len + 2 // the first line's field, space and LF
	mut k := 0
	for k < text.len {
		b := text[k]
		if b == `\r` || b == `\n` {
			if b == `\r` && k + 1 < text.len && text[k + 1] == `\n` {
				k++
			}
			n += field.len + 2
		} else {
			n++
		}
		k++
	}
	return n
}

// sse_lines writes text as "field: line" lines, splitting it at CRLF, CR and LF, as
// a client reads them (an empty text is one empty line).
fn sse_lines(mut out []u8, field string, text string) {
	append_str(mut out, field)
	out << ` `
	mut start := 0
	mut k := 0
	for k < text.len {
		b := text[k]
		if b == `\r` || b == `\n` {
			unsafe { out.push_many(text.str + start, k - start) }
			out << `\n`
			append_str(mut out, field)
			out << ` `
			if b == `\r` && k + 1 < text.len && text[k + 1] == `\n` {
				k++
			}
			start = k + 1
		}
		k++
	}
	unsafe { out.push_many(text.str + start, text.len - start) }
	out << `\n`
}

// chunk_head starts a chunk of n bytes: its size in hex and CRLF.
fn chunk_head(mut out []u8, n int) {
	mut tmp := [8]u8{}
	mut i := 8
	mut v := u32(n)
	for {
		i--
		d := v & 0xf
		tmp[i] = if d < 10 { u8(`0` + d) } else { u8(`a` + d - 10) }
		v >>= 4
		if v == 0 {
			break
		}
	}
	unsafe { out.push_many(&tmp[i], 8 - i) }
	append_str(mut out, crlf)
}

// --- answering with a stream ---

// stream answers with status and a body written over time by h's callbacks, which
// run once the handler returns; on_open first, with this request. The body is sent
// chunked to HTTP/1.1 clients and closes the connection when it ends for HTTP/1.0
// ones. A HEAD request, or a status without a body, gets the head alone. Middleware
// that rewrites bodies (gzip) leaves a stream alone.
pub fn (mut c Ctx) stream(status int, content_type string, h &StreamHandler) {
	c.open_stream(status, content_type, h, false)
}

// sse answers with a Server-Sent Events stream (text/event-stream) run by h: write
// events with Stream.event, comments with Stream.comment.
pub fn (mut c Ctx) sse(h &StreamHandler) {
	c.set_header('Cache-Control', 'no-cache')
	c.set_header('X-Accel-Buffering', 'no') // nginx buffers responses, a stream too, without it
	c.open_stream(200, 'text/event-stream', h, true)
}

fn (mut c Ctx) open_stream(status int, content_type string, h &StreamHandler, sse bool) {
	if c.responded || c.deferred {
		$if viltrum_debug ? {
			panic('viltrum: stream() on a request that already has a response')
		}
		return
	}
	streams := c.head.method != .head && body_allowed(status)
	if c.head.minor == 0 {
		if streams {
			c.close_after = true // an HTTP/1.0 body without a length ends with the connection
		}
	} else if body_allowed(status) {
		c.set_header('Transfer-Encoding', 'chunked')
	}
	c.answer_head(status, content_type, '', -1)
	if !streams {
		return
	}
	c.st = unsafe { h }
	c.st_sse = sse
}
