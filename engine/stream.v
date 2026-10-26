module engine

import time
import viltrum.http1

// Streaming responses on the worker (Ctx.stream): once the head is in wbuf, the
// connection belongs to the route's StreamHandler until the stream ends. Its
// callbacks write straight into wbuf through the worker's Stream, which the event loop
// flushes as it does responses; requests the client pipelines meanwhile wait, as
// they do behind a deferred response. A stream ends with Stream.end, or when the
// connection goes away; on_close runs either way, once.

// what on_drain may write in one flush before the connection yields to the others
const stream_drain_max = 256 * 1024

// st_open takes the connection over after a stream's head; the Ctx still holds the
// request for on_open.
fn (mut w Worker) st_open(mut c Conn) {
	x := &w.ctx
	c.st = x.st
	c.st_sse = x.st_sse
	c.st_chunked = x.head.minor >= 1
	// a Connection: close, or HTTP/1.0's end of body, waits for the end of the stream
	c.st_close = c.close_after
	c.close_after = false
	c.st_data = unsafe { nil }
	c.st_serial++
	c.st_last = time.ticks()
	c.reading = false
	if !isnil(c.st.on_open) {
		mut s := w.st_lend(mut c)
		c.st.on_open(mut s, mut w.ctx)
		w.st_take(mut c)
	}
}

// st_lend points the worker's Stream at c for one callback.
fn (mut w Worker) st_lend(mut c Conn) &http1.Stream {
	mut s := &w.st
	s.out = c.wbuf
	s.data = c.st_data
	s.chunked = c.st_chunked
	s.sse = c.st_sse
	s.ended = false
	s.h = c.st
	s.me = http1.StreamId{
		worker: s.worker
		fd:     c.fd
		gen:    c.gen
		stream: c.st_serial
	}
	return s
}

// st_take takes back what a callback did: its writes, subscriptions, publishes and
// timers. A stream that ended is finished; one whose client lets more than four
// times max_pending pile up unread is too slow to keep and is closed.
fn (mut w Worker) st_take(mut c Conn) {
	mut s := &w.st
	if s.out.len != c.wbuf.len {
		c.st_last = time.ticks()
	}
	c.wbuf = s.out
	c.st_data = s.data
	if s.subs.len > 0 || s.posts.len > 0 {
		w.apply_topics(mut c, 0, mut c.subs, mut s.subs, mut s.posts, s.ended)
	}
	if s.timers.len > 0 {
		now := time.sys_mono_now()
		for i in 0 .. s.timers.len {
			t := &s.timers[i]
			ms := if t.ms > 0 { u64(t.ms) } else { u64(0) }
			w.timers.push_tick(now + ms * 1_000_000, c.fd, c.gen, c.st_serial, t.cb, t.arg)
		}
		s.timers.clear()
	}
	if s.ended {
		w.st_end(mut c)
		c.close_after = c.st_close || !c.st_chunked
	} else if c.wbuf.len - c.woff > 4 * w.opts.max_pending {
		c.close_after = true
	}
}

// st_end runs on_close as the stream ends or the connection goes away, once; writes
// from on_close are dropped, publishes go out. The stream leaves its topics.
pub fn (mut w Worker) st_end(mut c Conn) {
	h := c.st
	if isnil(h) {
		return
	}
	if !isnil(h.on_close) {
		mut s := w.st_lend(mut c)
		s.ended = true
		h.on_close(mut s)
		s.timers.clear()
		s.subs.clear()
		if s.posts.len > 0 {
			w.apply_topics(mut c, 0, mut c.subs, mut s.subs, mut s.posts, true)
		}
	}
	c.st = unsafe { nil }
	c.st_data = unsafe { nil }
	for c.subs.len > 0 {
		w.leave_topic(mut c, 0, mut c.subs, c.subs.len - 1)
	}
}

// st_tick runs a stream timer, if it is for c's current stream (on HTTP/2, the stream
// with that id); false when not.
fn (mut w Worker) st_tick(mut c Conn, stream u32, cb http1.StreamTick, arg u64) bool {
	if !isnil(c.h2) {
		return w.h2_st_tick(mut c, stream, cb, arg)
	}
	if isnil(c.st) || c.st_serial != stream || c.close_after {
		return false
	}
	mut s := w.st_lend(mut c)
	cb(mut s, arg)
	w.st_take(mut c)
	return true
}

// st_drain runs on_drain once everything written so far is out; true when it wrote.
fn (mut w Worker) st_drain(mut c Conn) bool {
	if isnil(c.st) || isnil(c.st.on_drain) || c.close_after {
		return false
	}
	before := c.wbuf.len
	mut s := w.st_lend(mut c)
	c.st.on_drain(mut s)
	w.st_take(mut c)
	return c.wbuf.len > before
}

// st_push writes bytes sent or published to c's stream from elsewhere, as one chunk.
fn (mut w Worker) st_push(mut c Conn, p &http1.WsPost, mut touched []&Conn) {
	if c.close_after {
		return
	}
	w.lend(mut c)
	if c.wbuf.len - c.woff > 4 * w.opts.max_pending {
		c.close_after = true // too slow: see st_take
	} else {
		mut s := w.st_lend(mut c)
		s.write(p.data)
		c.wbuf = s.out
		c.st_last = time.ticks()
	}
	if !c.touched {
		c.touched = true
		touched << c
	}
}

// st_heartbeat sends an SSE comment on a stream quiet for its handler's heartbeat;
// true when it did. now is time.ticks() ms.
fn (mut w Worker) st_heartbeat(mut c Conn, now i64) bool {
	if isnil(c.st) || !c.st_sse || c.close_after {
		return false
	}
	ms := c.st.heartbeat.milliseconds()
	if ms <= 0 || now - c.st_last < ms {
		return false
	}
	mut s := w.st_lend(mut c)
	s.comment('')
	c.wbuf = s.out
	c.st_last = now
	return true
}

// st_run_inline moves c's stream on in place, for process_waiting: on_drain while it
// writes, else the next of its timers, slept out. A stream with neither can never end
// and is closed.
fn (mut w Worker) st_run_inline(mut c Conn) {
	for _ in 0 .. 1000 {
		if !w.st_drain(mut c) {
			break
		}
	}
	if isnil(c.st) {
		return
	}
	if c.close_after {
		w.st_end(mut c)
		return
	}
	for w.timers.a.len > 0 {
		t := w.timers.pop()
		if t.tick == 0 {
			continue
		}
		for {
			now := time.sys_mono_now()
			if now >= t.due {
				break
			}
			time.sleep(time.Duration(i64(t.due - now)))
		}
		w.st_tick(mut c, t.stream, t.cb(), t.arg)
		return
	}
	w.st_end(mut c)
	c.close_after = true
}
