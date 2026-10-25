module engine

import time
import viltrum.http1
import viltrum.http2

// Streaming responses over HTTP/2 (Ctx.stream): the same StreamHandler as on HTTP/1.1,
// one per HTTP/2 stream, so a connection carries many at once beside its requests.
// The stream keeps a slot from its HEADERS until it ends. A callback writes raw into
// the slot's out, the worker's Stream lent to it as for HTTP/1.1; what it wrote is
// held output from then on, which h2_pump sends as DATA within the windows. end()
// sets END_STREAM on the last of it. on_drain runs when the slot has nothing left to
// send, so a generated body follows the client's stream window. A RST_STREAM from the
// client ends the stream as a closed connection does. See docs/design/1.x-streaming.md.

// h2_st_open starts the stream the Ctx answered stream id with: its head goes now,
// without END_STREAM, and the slot it takes runs on_open.
fn (mut w Worker) h2_st_open(mut c Conn, id u32, send_win i64) {
	mut x := &w.ctx
	hd := x.st
	sse := x.st_sse
	x.st = unsafe { nil }
	if !w.h2_respond(mut c, id, -1, 0, 0, send_win, true) {
		return
	}
	mut h := c.h2
	i := h.take(id, send_win)
	mut s := &h.streams[i]
	s.st = hd
	s.st_sse = sse
	s.st_data = unsafe { nil }
	s.st_last = time.ticks()
	h.streaming++
	if !isnil(hd.on_open) {
		mut st := w.h2_st_lend(mut c, i)
		hd.on_open(mut st, mut w.ctx)
		w.h2_st_take(mut c, i)
	}
}

// h2_st_lend points the worker's Stream at the stream in slot i for one callback.
fn (mut w Worker) h2_st_lend(mut c Conn, i int) &http1.Stream {
	mut h := c.h2
	mut slot := &h.streams[i]
	if slot.out_off > 0 {
		// what went out already makes room at the front
		rest := slot.out.len - slot.out_off
		if rest > 0 {
			unsafe { C.memmove(slot.out.data, &u8(slot.out.data) + slot.out_off, rest) }
		}
		unsafe {
			slot.out.len = rest
		}
		slot.out_off = 0
	}
	mut s := &w.st
	s.out = slot.out
	s.data = slot.st_data
	s.chunked = false // DATA frames carry the length
	s.sse = slot.st_sse
	s.ended = false
	s.h = slot.st
	s.me = http1.StreamId{
		worker: s.worker
		fd:     c.fd
		gen:    c.gen
		stream: slot.id
	}
	return s
}

// h2_st_take takes back what a callback did on the stream in slot i, as st_take does
// on HTTP/1.1: its writes become held output, then its subscriptions, publishes and
// timers. A stream that ended is finished; one holding more than four times
// max_pending that the client's windows keep back is too slow to keep and is reset.
// It returns the bytes written.
fn (mut w Worker) h2_st_take(mut c Conn, i int) int {
	mut h := c.h2
	mut slot := &h.streams[i]
	mut s := &w.st
	added := s.out.len - slot.out.len
	slot.out = s.out
	slot.st_data = s.data
	if added > 0 {
		slot.st_last = time.ticks()
		h.held += added
		if !slot.sending {
			slot.sending = true
			h.sending++
			h.sent++ // the stall timeout counts from now
		}
	}
	if s.subs.len > 0 || s.posts.len > 0 {
		w.apply_topics(mut c, slot.id, mut slot.subs, mut s.subs, mut s.posts, s.ended)
	}
	if s.timers.len > 0 {
		now := time.sys_mono_now()
		for k in 0 .. s.timers.len {
			t := &s.timers[k]
			ms := if t.ms > 0 { u64(t.ms) } else { u64(0) }
			w.timers.push_tick(now + ms * 1_000_000, c.fd, c.gen, slot.id, t.cb, t.arg)
		}
		s.timers.clear()
	}
	if s.ended {
		w.h2_st_end(mut c, i)
		if !slot.sending {
			// nothing held: the body ends now, else with the last DATA h2_pump sends
			h2_data_frames(mut c.wbuf, slot.id, unsafe { nil }, 0, true)
			h.release(i)
		}
	} else if slot.out.len - slot.out_off > 4 * w.opts.max_pending {
		w.h2_reset(mut c, slot.id, http2.err_cancel)
	}
	return added
}

// h2_st_end runs on_close as the stream in slot i ends, is reset, or its connection
// goes away, once; writes from on_close are dropped, publishes go out. The stream
// leaves its topics. Its slot stays, for output still held.
fn (mut w Worker) h2_st_end(mut c Conn, i int) {
	mut h := c.h2
	mut slot := &h.streams[i]
	hd := slot.st
	if isnil(hd) {
		return
	}
	if !isnil(hd.on_close) {
		mut s := w.h2_st_lend(mut c, i)
		s.ended = true
		hd.on_close(mut s)
		s.timers.clear()
		s.subs.clear()
		if s.posts.len > 0 {
			w.apply_topics(mut c, slot.id, mut slot.subs, mut s.subs, mut s.posts, true)
		}
	}
	slot.st = unsafe { nil }
	slot.st_data = unsafe { nil }
	h.streaming--
	for slot.subs.len > 0 {
		w.leave_topic(mut c, slot.id, mut slot.subs, slot.subs.len - 1)
	}
}

// h2_end_streams ends every stream on c, as the connection closes.
fn (mut w Worker) h2_end_streams(mut c Conn) {
	for i in 0 .. c.h2.streams.len {
		if c.h2.streaming == 0 {
			return
		}
		w.h2_st_end(mut c, i)
	}
}

// h2_st_slot is the slot of stream id while it is being written, or -1.
fn (h &H2Conn) h2_st_slot(id u32) int {
	if h.streaming == 0 {
		return -1
	}
	i := h.find(id)
	return if i >= 0 && !isnil(h.streams[i].st) { i } else { -1 }
}

// h2_st_tick runs a stream timer, if stream id is still being written; false when not.
fn (mut w Worker) h2_st_tick(mut c Conn, id u32, cb http1.StreamTick, arg u64) bool {
	i := c.h2.h2_st_slot(id)
	if i < 0 || c.close_after {
		return false
	}
	mut s := w.h2_st_lend(mut c, i)
	cb(mut s, arg)
	w.h2_st_take(mut c, i)
	return true
}

// h2_drain runs on_drain on every stream with nothing left to send; the bytes they
// wrote. Each such stream gets one call a pass, so none holds up the rest.
fn (mut w Worker) h2_drain(mut c Conn) int {
	mut h := c.h2
	if h.streaming == 0 || c.close_after {
		return 0
	}
	mut n := 0
	for i in 0 .. h.streams.len {
		slot := &h.streams[i]
		if slot.id == 0 || slot.sending || isnil(slot.st) || isnil(slot.st.on_drain) {
			continue
		}
		hd := slot.st
		mut s := w.h2_st_lend(mut c, i)
		hd.on_drain(mut s)
		n += w.h2_st_take(mut c, i)
		if c.close_after {
			break
		}
	}
	return n
}

// h2_st_push writes bytes sent or published to stream id from elsewhere.
fn (mut w Worker) h2_st_push(mut c Conn, id u32, p &http1.WsPost, mut touched []&Conn) {
	i := c.h2.h2_st_slot(id)
	if i < 0 || c.close_after {
		return
	}
	mut s := w.h2_st_lend(mut c, i)
	s.write(p.data)
	w.h2_st_take(mut c, i)
	if !c.touched {
		c.touched = true
		touched << c
	}
}

// h2_heartbeats sends an SSE comment on every stream quiet for its handler's
// heartbeat; true when it sent any. now is time.ticks() ms.
fn (mut w Worker) h2_heartbeats(mut c Conn, now i64) bool {
	mut h := c.h2
	if h.streaming == 0 || c.close_after {
		return false
	}
	mut sent := false
	for i in 0 .. h.streams.len {
		slot := &h.streams[i]
		if slot.id == 0 || !slot.st_sse || isnil(slot.st) {
			continue
		}
		ms := slot.st.heartbeat.milliseconds()
		if ms <= 0 || now - slot.st_last < ms {
			continue
		}
		mut s := w.h2_st_lend(mut c, i)
		s.comment('')
		w.h2_st_take(mut c, i)
		h.streams[i].st_last = now
		sent = true
	}
	return sent
}
