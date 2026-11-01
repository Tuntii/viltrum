module engine

import time
import viltrum.http1
import viltrum.http2

// HTTP/2 on the worker (RFC 9113): cleartext with prior knowledge, beside HTTP/1.1
// on the same listener. A request reaches the same router, middleware and Ctx as an
// HTTP/1.1 one: its decoded fields are written out as an HTTP/1.1 head, which
// http1.parse_head checks and indexes, so every rule a request is held to there holds
// here too. The handler writes its HTTP/1.1 response into a worker buffer, and that
// becomes a HEADERS frame and DATA frames, the DATA within the flow-control windows.
// What the windows hold back waits on its stream and goes out from h2_pump. See
// docs/design/1.x-http2.md.

const h2_max_streams = 128 // SETTINGS_MAX_CONCURRENT_STREAMS we announce
const h2_max_continuations = 32 // CONTINUATION frames one header block may take
const h2_flood = 1000 // control frames with no request answered in between, before ENHANCE_YOUR_CALM
// Output staged in wbuf before it is flushed: by h2_pump, and by h2_process answering
// the requests of one read. Past it the frames wait in rbuf for the next round. With
// a response on top it still fits the TLS records one send takes (tls13_out_records),
// so the write buffer is all sealed and can go back while the socket is full, and it
// stays 64 KiB: a 64 KiB batch was no faster and needed 128 KiB buffers.
const h2_pump_max = 32 * 1024

// H2Stream is a stream still in progress: its request's body is coming, or its
// response is held back by flow control. Streams that finish where they start (most)
// never take one.
struct H2Stream {
mut:
	id        u32  // 0: the slot is free
	receiving bool // the request's body is still coming
	sending   bool // its response is held back
	head      []u8 // the request's HTTP/1.1 head, while its body comes
	body      []u8
	recv_win  i64 // what the client may still send on it
	length    i64 = -1 // the request's content-length, checked against its DATA
	send_win  i64  // what we may still send on it
	out       []u8 // response body held back, from out_off
	out_off   int
	file_fd   int = -1 // a file answer, sent after out
	file_off  i64
	file_left i64
	// a deferred response (Ctx.after): its timer is on the worker
	waiting bool
	cb      http1.Resume = unsafe { nil }
	arg     u64
	method  http1.Method
	// a streaming response (Ctx.stream), from its head until it ends (h2_stream.v);
	// what it writes waits in out like a held response
	st      &http1.StreamHandler = unsafe { nil }
	st_data voidptr
	st_sse  bool
	st_last i64      // when it last wrote, in time.ticks() ms, for the heartbeat
	subs    []&Topic // topics it is subscribed to
}

// H2Conn is the HTTP/2 state of one connection.
@[heap]
struct H2Conn {
mut:
	dec         &http2.Decoder = unsafe { nil }
	enc         &http2.Encoder = unsafe { nil }
	preface     bool // the client preface was read
	settings    bool // and the client's SETTINGS, which must come first
	last_id     u32  // the highest stream the client opened
	peer_window i64 = http2.default_window // its SETTINGS_INITIAL_WINDOW_SIZE
	send_win    i64 = http2.default_window // the connection's send window
	recv_win    i64 // what the client may still send on the connection
	recv_max    i64 // the connection receive window, given back as DATA is read
	owed        i64 // DATA read and not given back yet
	// request bodies are bounded per stream, not per connection (see h2_credit)
	stream_win i64  // the receive window each stream starts with
	bodies     int  // streams whose request body is still coming
	buffered   i64  // body bytes held by them
	budget     i64  // past this, only the oldest such stream's window grows
	withheld   bool // some stream's window waits for buffered to fall
	hblock     []u8 // a header block arriving in HEADERS and CONTINUATION frames
	hstream    u32  // its stream, 0 when none
	hflags     u8   // its HEADERS frame's flags
	hframes    int
	hself      bool // its HEADERS made the stream depend on itself
	hignore    bool // it is on a stream we reset or answered early: decoded, then dropped
	streams    []H2Stream
	open       int // streams in use
	sending    int // streams with output held back
	waiting    int // streams whose response is deferred
	streaming  int // streams whose body is still being written (Ctx.stream)
	held       i64 // response bytes held back in slots
	files      int // file answers held back
	pump_next  int // the slot h2_pump starts its next pass at
	flood      int
	resets     [16]u32 // the last streams we reset, whose frames in flight are ignored
	reset_pos  int
	// what the stall timeout reads: DATA sent from held streams, and when it last moved
	sent      u64
	sent_seen u64
	progress  i64
}

const h2_max_files = 32 // file answers held back at once on a connection

// h2_preface_state is 1 when buf starts with the HTTP/2 preface, 0 while it could
// still (too short to tell), -1 when it cannot (an HTTP/1.1 request), and -2 for a
// preface that goes wrong after its request line: an HTTP/2 client, but not one that
// can be served.
fn h2_preface_state(buf []u8) int {
	n := if buf.len < http2.preface.len { buf.len } else { http2.preface.len }
	for k in 0 .. n {
		if buf[k] != http2.preface[k] {
			return if k >= h2_preface_line { -2 } else { -1 }
		}
	}
	return if n == http2.preface.len { 1 } else { 0 }
}

const h2_preface_line = 16 // 'PRI * HTTP/2.0\r\n'

// h2_open makes c an HTTP/2 connection and queues our SETTINGS and the connection
// window we keep.
fn (mut w Worker) h2_open(mut c Conn) {
	if isnil(c.h2_keep) {
		c.h2_keep = &H2Conn{ // cold: once per pooled Conn
			dec: http2.new_decoder(http2.default_table_size)
			enc: http2.new_encoder(http2.default_table_size)
		}
	}
	if w.h2out.cap == 0 {
		w.h2_buffers() // cold: once per worker
	}
	mut h := c.h2_keep
	h.dec.reset()
	h.enc.reset()
	h.preface = false
	h.settings = false
	h.last_id = 0
	h.peer_window = http2.default_window
	h.send_win = http2.default_window
	max_body := i64(w.opts.limits.max_body_bytes)
	// the default, so DATA sent before our SETTINGS arrive is still in bounds; h2_credit
	// never opens a stream past one byte over the body limit
	h.stream_win = http2.default_window
	h.budget = if max_body > http2.default_window { max_body } else { i64(http2.default_window) }
	h.recv_max = h.budget
	h.recv_win = h.recv_max
	h.owed = 0
	h.bodies = 0
	h.buffered = 0
	h.withheld = false
	unsafe {
		h.hblock.len = 0
	}
	h.hstream = 0
	h.open = 0
	h.sending = 0
	h.waiting = 0
	h.streaming = 0
	h.held = 0
	h.files = 0
	h.pump_next = 0
	h.flood = 0
	h.resets = [16]u32{}
	h.reset_pos = 0
	h.sent = 0
	h.sent_seen = 0
	c.h2 = h
	c.h2_ok = false
	http2.write_frame_header(mut c.wbuf, 18, http2.frame_settings, 0, 0)
	h2_setting(mut c.wbuf, http2.settings_max_concurrent_streams, h2_max_streams)
	h2_setting(mut c.wbuf, http2.settings_initial_window_size, u32(h.stream_win))
	h2_setting(mut c.wbuf, http2.settings_max_header_list_size, u32(w.opts.limits.max_header_bytes))
	if h.recv_max > http2.default_window {
		h2_window_update(mut c.wbuf, 0, u32(h.recv_max - http2.default_window))
	}
}

// h2_buffers sizes the worker's HTTP/2 scratch buffers.
fn (mut w Worker) h2_buffers() {
	w.h2dec = []u8{cap: 4096}
	w.h2req = []u8{cap: 4096}
	w.h2out = []u8{cap: write_buf_size}
	w.h2blk = []u8{cap: 1024}
}

fn h2_setting(mut out []u8, id int, v u32) {
	out << u8(id >> 8)
	out << u8(id)
	http2.put_u32(mut out, v)
}

fn h2_window_update(mut out []u8, id u32, n u32) {
	http2.write_frame_header(mut out, 4, http2.frame_window_update, 0, id)
	http2.put_u32(mut out, n)
}

// h2_reset ends stream id with RST_STREAM: its slot, if it has one, is freed first so
// nothing more is sent on it, and frames the client sent before seeing the reset are
// ignored rather than taken as errors (RFC 9113 5.1).
fn (mut w Worker) h2_reset(mut c Conn, id u32, code u32) {
	mut h := c.h2
	i := h.find(id)
	if i >= 0 {
		w.h2_st_end(mut c, i)
		h.release(i)
		w.h2_credit_all(mut c)
	}
	h.resets[h.reset_pos] = id
	h.reset_pos = (h.reset_pos + 1) % h.resets.len
	http2.write_frame_header(mut c.wbuf, 4, http2.frame_rst_stream, 0, id)
	http2.put_u32(mut c.wbuf, code)
}

// was_reset is whether we reset stream id lately.
fn (h &H2Conn) was_reset(id u32) bool {
	for r in h.resets {
		if r == id {
			return true
		}
	}
	return false
}

// h2_fail ends the connection with a connection error: GOAWAY, then close once it is
// out (lingering, since the client may be mid-send).
fn (mut w Worker) h2_fail(mut c Conn, code u32) {
	if c.close_after {
		return
	}
	http2.write_frame_header(mut c.wbuf, 8, http2.frame_goaway, 0, 0)
	http2.put_u32(mut c.wbuf, c.h2.last_id)
	http2.put_u32(mut c.wbuf, code)
	c.close_after = true
	c.linger = true
}

// h2_process handles every whole frame buffered in c.rbuf and compacts what is left.
fn (mut w Worker) h2_process(mut c Conn) {
	mut h := c.h2
	mut off := 0
	w.lend_big(mut c)
	if !h.preface {
		// checked here as well as on a cleartext listener: after ALPN the connection is
		// HTTP/2 before its first byte
		state := h2_preface_state(c.rbuf)
		if state == 0 {
			c.reading = true
			return
		}
		if state < 0 {
			w.h2_fail(mut c, http2.err_protocol)
			unsafe {
				c.rbuf.len = 0
			}
			return
		}
		off = http2.preface.len
		h.preface = true
	}
	for !c.close_after && c.wbuf.len < w.opts.max_pending && c.wbuf.len < h2_pump_max {
		avail := c.rbuf.len - off
		if avail < http2.frame_header_len {
			break
		}
		p := unsafe { &u8(c.rbuf.data) + off }
		fh := http2.read_frame_header(p)
		if fh.length > http2.default_frame_size {
			// we never raise SETTINGS_MAX_FRAME_SIZE
			w.h2_fail(mut c, http2.err_frame_size)
			break
		}
		if avail < http2.frame_header_len + fh.length {
			break // the event loop grows rbuf to hold a whole frame
		}
		payload := http1.view(c.rbuf, off + http2.frame_header_len, fh.length)
		off += http2.frame_header_len + fh.length
		if !h.settings && (fh.typ != http2.frame_settings || fh.flags & http2.flag_ack != 0) {
			w.h2_fail(mut c, http2.err_protocol) // RFC 9113 3.4: SETTINGS comes first
			break
		}
		if h.hstream != 0 && (fh.typ != http2.frame_continuation || fh.stream != h.hstream) {
			w.h2_fail(mut c, http2.err_protocol) // a header block is never interleaved
			break
		}
		t := fh.typ
		if t == http2.frame_data {
			w.h2_on_data(mut c, fh, payload)
		} else if t == http2.frame_headers {
			w.h2_on_headers(mut c, fh, payload)
		} else if t == http2.frame_continuation {
			w.h2_on_continuation(mut c, fh, payload)
		} else if t == http2.frame_settings {
			w.h2_on_settings(mut c, fh, payload)
		} else if t == http2.frame_ping {
			w.h2_on_ping(mut c, fh, payload)
		} else if t == http2.frame_window_update {
			w.h2_on_window_update(mut c, fh, payload)
		} else if t == http2.frame_rst_stream {
			w.h2_on_rst(mut c, fh)
		} else if t == http2.frame_priority {
			w.h2_on_priority(mut c, fh, payload)
		} else if t == http2.frame_goaway {
			w.h2_on_goaway(mut c, fh)
		} else if t == http2.frame_push_promise {
			w.h2_fail(mut c, http2.err_protocol) // clients do not push
		} else {
			h.flood++ // unknown types are ignored (RFC 9113 4.1), but not for free
		}
		if h.flood > h2_flood {
			w.h2_fail(mut c, http2.err_enhance_your_calm)
		}
	}
	if !c.close_after && h.owed > 0 && h.recv_win <= h.recv_max / 2 {
		h2_window_update(mut c.wbuf, 0, u32(h.owed))
		h.recv_win += h.owed
		h.owed = 0
	}
	if c.close_after {
		off = c.rbuf.len
	}
	rest := c.rbuf.len - off
	if off > 0 {
		if rest > 0 {
			unsafe { C.memmove(c.rbuf.data, &u8(c.rbuf.data) + off, rest) }
		}
		unsafe {
			c.rbuf.len = rest
		}
	}
	// a frame cut short or a request still coming runs under the read timeout
	c.reading = rest > 0 || h.hstream != 0 || h.bodies > 0
}

// find is the slot of stream id, or -1.
fn (h &H2Conn) find(id u32) int {
	for i, s in h.streams {
		if s.id == id {
			return i
		}
	}
	return -1
}

// take is a free slot for stream id.
fn (mut h H2Conn) take(id u32, send_win i64) int {
	mut i := h.find(0)
	if i < 0 {
		h.streams << H2Stream{} // cold: grows to the most streams ever in progress at once
		i = h.streams.len - 1
	}
	mut s := &h.streams[i]
	s.id = id
	s.receiving = false
	s.sending = false
	s.waiting = false
	s.st = unsafe { nil }
	unsafe {
		s.head.len = 0
		s.body.len = 0
		s.out.len = 0
	}
	s.recv_win = h.stream_win
	s.length = -1
	s.send_win = send_win
	s.out_off = 0
	s.file_fd = -1
	s.file_left = 0
	h.open++
	return i
}

// release frees slot i: its file closed, its body's bytes out of buffered.
fn (mut h H2Conn) release(i int) {
	mut s := &h.streams[i]
	if s.id == 0 {
		return
	}
	if s.sending {
		h.sending--
		h.held -= s.out.len - s.out_off
		s.sending = false
	}
	if s.receiving {
		h.buffered -= s.body.len
		h.bodies--
		s.receiving = false
	}
	if s.waiting {
		h.waiting-- // its timer finds the stream gone and is dropped
		s.waiting = false
	}
	if !isnil(s.st) {
		// h2_st_end ran first wherever a stream can end; this is the backstop
		h.streaming--
		s.st = unsafe { nil }
		s.st_data = unsafe { nil }
	}
	if s.file_fd >= 0 {
		http1.close_file(s.file_fd)
		s.file_fd = -1
		h.files--
	}
	s.file_left = 0
	s.id = 0
	h.open--
	// what one large request or response grew is given back
	if s.body.cap > shrink_rbuf_above {
		s.body = []u8{} // cold
	}
	if s.head.cap > shrink_rbuf_above {
		s.head = []u8{} // cold
	}
	if s.out.cap > shrink_wbuf_above {
		s.out = []u8{} // cold
	}
}

// oldest_receiving is the lowest stream whose request is still coming, 0 when none.
fn (h &H2Conn) oldest_receiving() u32 {
	mut id := u32(0)
	for s in h.streams {
		if s.id != 0 && s.receiving && (id == 0 || s.id < id) {
			id = s.id
		}
	}
	return id
}

// h2_credit opens stream i's window again as its body is read: back to the size it
// started at, never past one byte over the body limit. While the bodies held on the
// connection pass the budget, only the oldest stream gets more; the others wait for
// h2_credit_all. The connection window is given back as DATA is read, so the
// connection never waits on a stream, and the oldest stream can always finish:
// nothing waits on anything that waits on it.
fn (mut w Worker) h2_credit(mut c Conn, i int) {
	mut h := c.h2
	mut s := &h.streams[i]
	room := i64(w.opts.limits.max_body_bytes) + 1 - s.body.len
	target := if room < h.stream_win { room } else { h.stream_win }
	credit := target - s.recv_win
	// small updates wait until half the window is used, unless the limit is near
	if credit <= 0 || (credit < h.stream_win / 2 && target == h.stream_win) {
		return
	}
	if h.buffered > h.budget && s.id != h.oldest_receiving() {
		h.withheld = true
		return
	}
	h2_window_update(mut c.wbuf, s.id, u32(credit))
	s.recv_win += credit
}

// h2_credit_all gives the streams their withheld window updates once a request
// finishes and buffered falls.
fn (mut w Worker) h2_credit_all(mut c Conn) {
	mut h := c.h2
	if !h.withheld || c.close_after {
		return
	}
	h.withheld = false
	for i in 0 .. h.streams.len {
		if h.streams[i].id != 0 && h.streams[i].receiving {
			w.h2_credit(mut c, i)
		}
	}
}

// close_streams releases every stream, when the connection closes.
fn (mut h H2Conn) close_streams() {
	for i in 0 .. h.streams.len {
		h.release(i)
	}
	if h.hblock.cap > shrink_rbuf_above {
		h.hblock = []u8{} // cold: a large header block
	}
}

// strip_padding is the payload without its padding (RFC 9113 6.1), skipping skip
// bytes after the pad length too; false when the padding does not fit.
fn strip_padding(fh http2.FrameHeader, payload []u8, skip int, mut out []u8) bool {
	mut start := 0
	mut end := payload.len
	if fh.flags & http2.flag_padded != 0 {
		if payload.len < 1 {
			return false
		}
		pad := int(payload[0])
		start = 1
		end -= pad
	}
	start += skip
	if start > end {
		return false
	}
	out = http1.view(payload, start, end - start)
	return true
}

fn (mut w Worker) h2_on_data(mut c Conn, fh http2.FrameHeader, payload []u8) {
	mut h := c.h2
	if fh.stream == 0 {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	h.recv_win -= fh.length
	if h.recv_win < 0 {
		w.h2_fail(mut c, http2.err_flow_control)
		return
	}
	h.owed += fh.length // read now, so given back (h2_process sends it)
	i := h.find(fh.stream)
	if i < 0 || !h.streams[i].receiving {
		h.flood++ // nothing served, whichever way it is dropped
		if fh.stream > h.last_id {
			w.h2_fail(mut c, http2.err_protocol) // DATA on a stream never opened
		} else if i < 0 && !h.was_reset(fh.stream) {
			w.h2_reset(mut c, fh.stream, http2.err_stream_closed)
		}
		// else the rest of a body we answered early, or sent before our reset: dropped
		return
	}
	mut data := []u8{}
	if !strip_padding(fh, payload, 0, mut data) {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	mut s := &h.streams[i]
	s.recv_win -= fh.length
	if s.recv_win < 0 {
		w.h2_reset(mut c, fh.stream, http2.err_flow_control)
		return
	}
	if data.len == 0 && fh.flags & http2.flag_end_stream == 0 {
		h.flood++ // empty DATA frames do nothing but cost
	}
	if s.body.len + data.len > w.opts.limits.max_body_bytes {
		send_win := s.send_win
		h.release(i)
		w.h2_credit_all(mut c)
		w.h2_error(mut c, fh.stream, 413, 'payload too large', send_win)
		w.h2_early_answer(mut c, fh.stream)
		return
	}
	unsafe { s.body.push_many(data.data, data.len) }
	h.buffered += data.len
	if fh.flags & http2.flag_end_stream != 0 {
		w.h2_request_done(mut c, i)
	} else {
		w.h2_credit(mut c, i)
	}
}

// h2_request_done serves stream i once its body is complete.
fn (mut w Worker) h2_request_done(mut c Conn, i int) {
	mut h := c.h2
	mut s := &h.streams[i]
	id := s.id
	if s.length >= 0 && s.length != s.body.len {
		w.h2_reset(mut c, id, http2.err_protocol) // content-length disagrees with the DATA (RFC 9113 8.1.1)
		return
	}
	// the head and body move to the worker, so the slot can take the response; the
	// window the client gave the stream meanwhile goes with it
	send_win := s.send_win
	unsafe {
		w.h2req.len = 0
		w.h2req.push_many(s.head.data, s.head.len)
		w.h2body.len = 0
		w.h2body.push_many(s.body.data, s.body.len)
	}
	h.release(i)
	w.h2_credit_all(mut c)
	w.h2_serve(mut c, id, http1.view(w.h2body, 0, w.h2body.len), send_win)
	if w.h2body.cap > shrink_rbuf_above {
		w.h2body = []u8{} // cold: a large body
	}
}

// h2_early_answer follows a response sent before its request's body ended (413, 431):
// once the response is all out, RST_STREAM(NO_ERROR) tells the client to stop sending
// (RFC 9113 8.1). While it is held back, the body's DATA is dropped as it comes.
fn (mut w Worker) h2_early_answer(mut c Conn, id u32) {
	if c.h2.find(id) < 0 {
		w.h2_reset(mut c, id, http2.err_no_error)
	}
}

fn (mut w Worker) h2_on_headers(mut c Conn, fh http2.FrameHeader, payload []u8) {
	mut h := c.h2
	if fh.stream == 0 || fh.stream % 2 == 0 {
		w.h2_fail(mut c, http2.err_protocol) // clients open odd streams
		return
	}
	skip := if fh.flags & http2.flag_priority != 0 { 5 } else { 0 }
	mut frag := []u8{}
	if !strip_padding(fh, payload, skip, mut frag) {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	h.hself = false
	if skip > 0 {
		start := if fh.flags & http2.flag_padded != 0 { 1 } else { 0 }
		dep := unsafe { http2.get_u32(&u8(payload.data) + start) } & 0x7fffffff
		// a stream depending on itself is a stream error (RFC 9113 5.3.1), once its
		// block is decoded
		h.hself = dep == fh.stream
	}
	h.hignore = false
	if fh.stream <= h.last_id {
		// trailers, on a stream whose body is coming. On a stream we reset or answered
		// early they are in flight from before, and only decoded; anything else reuses
		// a closed id.
		i := h.find(fh.stream)
		if i < 0 || !h.streams[i].receiving {
			if !h.was_reset(fh.stream) && i < 0 {
				w.h2_fail(mut c, http2.err_stream_closed)
				return
			}
			h.hignore = true
		}
	}
	unsafe {
		h.hblock.len = 0
		h.hblock.push_many(frag.data, frag.len)
	}
	h.hflags = fh.flags
	h.hframes = 0
	if fh.flags & http2.flag_end_headers == 0 {
		h.hstream = fh.stream
		return
	}
	w.h2_block(mut c, fh.stream)
}

fn (mut w Worker) h2_on_continuation(mut c Conn, fh http2.FrameHeader, payload []u8) {
	mut h := c.h2
	if h.hstream == 0 {
		w.h2_fail(mut c, http2.err_protocol) // CONTINUATION after nothing
		return
	}
	h.hframes++
	if h.hframes > h2_max_continuations
		|| h.hblock.len + payload.len > w.opts.limits.max_header_bytes {
		// the block cannot be decoded in part, so the connection cannot go on
		w.h2_fail(mut c, http2.err_enhance_your_calm)
		return
	}
	unsafe { h.hblock.push_many(payload.data, payload.len) }
	if fh.flags & http2.flag_end_headers != 0 {
		h.hstream = 0
		w.h2_block(mut c, fh.stream)
	}
}

// h2_block decodes the header block now complete on stream id: a new request, or the
// trailers of one whose body is coming.
fn (mut w Worker) h2_block(mut c Conn, id u32) {
	mut h := c.h2
	end := h.hflags & http2.flag_end_stream != 0
	unsafe {
		w.h2dec.len = 0
	}
	// decoded even when the stream is refused, to keep the table in step
	r := h.dec.decode(h.hblock, mut w.h2dec, mut w.h2fs, w.opts.limits.max_header_bytes)
	if r == http2.hpack_bad {
		w.h2_fail(mut c, http2.err_compression)
		return
	}
	if h.hignore {
		return
	}
	if id <= h.last_id {
		i := h.find(id)
		if !end {
			w.h2_reset(mut c, id, http2.err_protocol) // trailers end the stream
			return
		}
		w.h2_request_done(mut c, i) // the trailers themselves are not passed on
		return
	}
	h.last_id = id
	if h.hself {
		w.h2_reset(mut c, id, http2.err_protocol)
		return
	}
	// a stream more than we announced, or one more while what is held back waiting on
	// the client's windows is already as much as an HTTP/1.1 connection may hold
	if h.open >= h2_max_streams || h.held >= w.opts.max_pending || h.files >= h2_max_files {
		w.h2_reset(mut c, id, http2.err_refused_stream)
		return
	}
	// a body more while the windows the streams already receiving were opened with
	// add up to the budget: each may fill its window before h2_credit withholds, so
	// without this a connection could hold 128 of them, far more than max_body_bytes
	if !end && i64(h.bodies + 1) * h.stream_win > h.budget {
		w.h2_reset(mut c, id, http2.err_refused_stream)
		return
	}
	if r == http2.hpack_too_large {
		w.h2_error(mut c, id, 431, 'request header fields too large', h.peer_window)
		if !end {
			w.h2_early_answer(mut c, id)
		}
		return
	}
	length := w.h2_head()
	if length < -1 {
		h.flood++ // decoded and refused: no request answered
		w.h2_reset(mut c, id, http2.err_protocol) // a malformed request (RFC 9113 8.1.1)
		return
	}
	if end {
		if length > 0 {
			w.h2_reset(mut c, id, http2.err_protocol)
			return
		}
		w.h2_serve(mut c, id, http1.view(w.h2req, 0, 0), h.peer_window)
		return
	}
	i := h.take(id, h.peer_window)
	mut s := &h.streams[i]
	s.receiving = true
	h.bodies++
	s.length = length
	unsafe { s.head.push_many(w.h2req.data, w.h2req.len) }
}

// h2_head writes the request in w.h2dec / w.h2fs out as an HTTP/1.1 head in w.h2req.
// It returns the request's content-length, -1 without one, or -2 when the request is
// malformed (RFC 9113 8.2 and 8.3): pseudo-fields missing, repeated, unknown or after a
// regular one; a name with uppercase or a non-token byte; a value with NUL, CR or LF,
// or space at either end; a connection-specific field.
fn (mut w Worker) h2_head() i64 {
	buf := w.h2dec
	mut method := -1
	mut scheme := -1
	mut path := -1
	mut authority := -1
	mut length := i64(-1)
	mut cookies := 0
	mut regular := false
	for k in 0 .. w.h2fs.n {
		f := w.h2fs.f[k]
		if f.name_len == 0 || !h2_value_ok(buf, f.value_off, f.value_len) {
			return -2
		}
		if buf[f.name_off] == `:` {
			if regular {
				return -2
			}
			name := http1.str_view(buf, f.name_off, f.name_len)
			match name {
				':method' {
					if method >= 0 {
						return -2
					}
					method = k
				}
				':scheme' {
					if scheme >= 0 {
						return -2
					}
					scheme = k
				}
				':path' {
					if path >= 0 || f.value_len == 0 {
						return -2
					}
					path = k
				}
				':authority' {
					if authority >= 0 {
						return -2
					}
					authority = k
				}
				else {
					return -2
				}
			}

			continue
		}
		regular = true
		for j in 0 .. f.name_len {
			b := buf[f.name_off + j]
			if (b >= `A` && b <= `Z`) || !http1.is_tchar(b) {
				return -2
			}
		}
		name := http1.str_view(buf, f.name_off, f.name_len)
		match name {
			'connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade' {
				return -2
			}
			'te' {
				if http1.str_view(buf, f.value_off, f.value_len) != 'trailers' {
					return -2
				}
			}
			'content-length' {
				if f.value_len == 0 || f.value_len > 18 {
					return -2
				}
				mut n := i64(0)
				for j in 0 .. f.value_len {
					d := buf[f.value_off + j]
					if d < `0` || d > `9` {
						return -2
					}
					n = n * 10 + i64(d - `0`)
				}
				if length >= 0 && n != length {
					return -2
				}
				length = n
			}
			'cookie' {
				cookies++
			}
			else {}
		}
	}
	if method < 0 || scheme < 0 || path < 0 {
		return -2 // CONNECT, which leaves the last two out, is not served
	}
	m := w.h2fs.f[method]
	p := w.h2fs.f[path]
	pb := buf[p.value_off]
	if pb != `/` && !(pb == `*` && p.value_len == 1) {
		return -2
	}
	unsafe {
		w.h2req.len = 0
		w.h2req.push_many(&u8(buf.data) + m.value_off, m.value_len)
		w.h2req << ` `
		w.h2req.push_many(&u8(buf.data) + p.value_off, p.value_len)
	}
	http1.append_str(mut w.h2req, ' HTTP/1.1\r\n')
	if authority >= 0 {
		a := w.h2fs.f[authority]
		http1.append_str(mut w.h2req, 'host: ')
		unsafe { w.h2req.push_many(&u8(buf.data) + a.value_off, a.value_len) }
		http1.append_str(mut w.h2req, http1.crlf)
	}
	// HTTP/1.1 takes cookies on one line, joined with "; " (RFC 9113 8.2.3)
	join := cookies > 1
	mut left := cookies
	for k in 0 .. w.h2fs.n {
		f := w.h2fs.f[k]
		if buf[f.name_off] == `:` {
			continue
		}
		name := http1.str_view(buf, f.name_off, f.name_len)
		if authority >= 0 && name == 'host' {
			continue // :authority stands for it (RFC 9113 8.3.1)
		}
		if join && name == 'cookie' {
			http1.append_str(mut w.h2req, if left == cookies { 'cookie: ' } else { '; ' })
			unsafe { w.h2req.push_many(&u8(buf.data) + f.value_off, f.value_len) }
			left--
			if left == 0 {
				http1.append_str(mut w.h2req, http1.crlf)
			}
			continue
		}
		unsafe {
			w.h2req.push_many(&u8(buf.data) + f.name_off, f.name_len)
			w.h2req << `:`
			w.h2req << ` `
			w.h2req.push_many(&u8(buf.data) + f.value_off, f.value_len)
		}
		http1.append_str(mut w.h2req, http1.crlf)
	}
	http1.append_str(mut w.h2req, http1.crlf)
	return length
}

// h2_value_ok is whether buf[off..off+n] is a valid field value: no NUL, CR or LF, and
// no space or tab at either end.
fn h2_value_ok(buf []u8, off int, n int) bool {
	if n > 0 {
		first := buf[off]
		last := buf[off + n - 1]
		if first == ` ` || first == `\t` || last == ` ` || last == `\t` {
			return false
		}
	}
	for k in off .. off + n {
		b := buf[k]
		if b == 0 || b == `\r` || b == `\n` {
			return false
		}
	}
	return true
}

// h2_serve runs the request whose HTTP/1.1 head is in w.h2req, with body, and sends
// its response on stream id, which the client lets us send send_win on.
fn (mut w Worker) h2_serve(mut c Conn, id u32, body []u8, send_win i64) {
	mut x := &w.ctx
	msg := http1.view(w.h2req, 0, w.h2req.len)
	http1.parse_head(msg, msg.len, mut x.head) or {
		status := if err.code() >= 400 { err.code() } else { 400 }
		w.h2_error(mut c, id, status, err.msg(), send_win)
		return
	}
	if x.head.nfields > w.opts.limits.max_headers {
		w.h2_error(mut c, id, 431, 'too many header fields', send_win)
		return
	}
	if w.opts.require_host && !x.head.host_seen {
		w.h2_error(mut c, id, 400, 'missing host header', send_win)
		return
	}
	unsafe {
		w.h2out.len = 0
	}
	x.out = w.h2out
	x.begin(msg)
	x.set_body(body)
	idx := w.run_chain(mut x)
	w.requests++
	c.h2.flood = 0
	w.h2_finish(mut c, id, idx, send_win)
}

// h2_finish sends the Ctx's response on stream id, or parks the stream when the
// response is deferred. idx is the route lookup result, as for finish.
fn (mut w Worker) h2_finish(mut c Conn, id u32, idx int, send_win i64) {
	mut x := &w.ctx
	w.h2out = x.out
	if x.deferred {
		x.deferred = false
		w.h2_defer(mut c, id, send_win)
		return
	}
	if !isnil(x.ws) {
		w.h2_error(mut c, id, 501, 'WebSocket needs HTTP/1.1', send_win) // no RFC 8441 here
		return
	}
	if !isnil(x.st) {
		w.h2_st_open(mut c, id, send_win)
		return
	}
	w.answer_default(idx)
	w.h2out = x.out
	file_fd := x.file_fd
	x.file_fd = -1
	w.h2_respond(mut c, id, file_fd, x.file_off, x.file_left, send_win, false)
	if w.h2out.cap > shrink_wbuf_above {
		w.h2out = []u8{cap: write_buf_size} // cold: a large response
	}
}

// h2_defer parks stream id until its deferred response (Ctx.after) is due. Only the
// stream waits: its slot keeps the callback and follows the client's window, and the
// rest of the connection goes on.
fn (mut w Worker) h2_defer(mut c Conn, id u32, send_win i64) {
	mut x := &w.ctx
	mut h := c.h2
	i := h.take(id, send_win)
	mut s := &h.streams[i]
	s.waiting = true
	s.cb = x.defer_cb
	s.arg = x.defer_arg
	s.method = x.head.method
	h.waiting++
	w.timers.push(time.sys_mono_now() + u64(x.defer_ms) * 1_000_000, c.fd, c.gen, id)
}

// h2_resume writes the response deferred on stream id, when its timer is due; false
// when the stream no longer waits for it (the client reset it, or the connection is
// closing).
fn (mut w Worker) h2_resume(mut c Conn, id u32) bool {
	mut h := c.h2
	i := h.find(id)
	if c.close_after || i < 0 || !h.streams[i].waiting {
		return false
	}
	s := &h.streams[i]
	cb := s.cb
	arg := s.arg
	method := s.method
	send_win := s.send_win
	h.release(i)
	mut x := &w.ctx
	unsafe {
		w.h2out.len = 0
	}
	x.out = w.h2out
	x.begin_resumed(method, 1, true)
	cb(mut x, arg)
	w.h2_finish(mut c, id, 0, send_win)
	return true
}

// h2_waits is whether an HTTP/2 connection is quiet but for deferred responses, which
// their timers answer, and streams, which write when their handlers like: nothing
// arriving in part, nothing held back or blocked going out. The idle timeout waits
// meanwhile, as it does for an HTTP/1.1 connection in either state.
fn (c &Conn) h2_waits() bool {
	return !isnil(c.h2) && (c.h2.waiting > 0 || c.h2.streaming > 0) && c.h2.sending == 0
		&& !c.reading && !c.out_armed
}

// h2_error answers stream id with status and a short text, as refuse does.
fn (mut w Worker) h2_error(mut c Conn, id u32, status int, reason string, send_win i64) {
	mut x := &w.ctx
	x.head.method = .get
	x.head.minor = 1
	x.head.keep_alive = true
	x.head.nfields = 0
	unsafe {
		w.h2out.len = 0
	}
	x.out = w.h2out
	x.begin(http1.view(w.h2req, 0, 0))
	x.text(status, reason)
	w.h2out = x.out
	w.h2_respond(mut c, id, -1, 0, 0, send_win, false)
}

// h2_respond turns the HTTP/1.1 response in w.h2out into frames on stream id: the
// head into a HEADERS block, the body (and the file after it, when file_fd >= 0)
// into DATA as the windows allow, the stream's starting at send_win. What they hold
// back waits on the stream. With open set the head alone goes, a stream's: its body
// follows. False when the stream was reset instead.
fn (mut w Worker) h2_respond(mut c Conn, id u32, file_fd int, file_off i64, file_left i64, send_win i64, open bool) bool {
	mut h := c.h2
	out := w.h2out
	has_file := file_fd >= 0 && file_left > 0
	if file_fd >= 0 && !has_file {
		http1.close_file(file_fd) // an empty file: nothing to send from it
	}
	// the status line is ours, "HTTP/1.1 NNN Reason\r\n", but a handler may have set
	// a status HTTP/2 cannot carry: not three digits, or 1xx (a final response is due)
	mut p := 9
	for p < out.len && out[p] != ` ` {
		p++
	}
	if p != 12 || out[9] < `2` || out[9] > `9` {
		if has_file {
			http1.close_file(file_fd)
		}
		w.h2_reset(mut c, id, http2.err_internal)
		return false
	}
	for p + 1 < out.len && !(out[p] == `\r` && out[p + 1] == `\n`) {
		p++
	}
	unsafe {
		w.h2blk.len = 0
	}
	h.enc.begin(mut w.h2blk)
	h.enc.field(mut w.h2blk, ':status', http1.str_view(out, 9, 3), .incremental)
	p += 2
	for p + 1 < out.len && !(out[p] == `\r` && out[p + 1] == `\n`) {
		ns := p
		for out[p] != `:` {
			p++
		}
		name := http1.str_view(out, ns, p - ns)
		p += 2 // ": "
		vs := p
		for out[p] != `\r` {
			p++
		}
		value := http1.str_view(out, vs, p - vs)
		p += 2
		if h2_hop_by_hop(name) {
			continue
		}
		h.enc.field(mut w.h2blk, name, value, h2_index(name))
	}
	p += 2
	body_len := out.len - p
	h2_headers_frames(mut c.wbuf, id, w.h2blk, body_len == 0 && !has_file && !open)
	if body_len == 0 && !has_file {
		return true
	}
	k := h.sendable(body_len, send_win)
	h2_data_frames(mut c.wbuf, id, unsafe { &u8(out.data) + p }, k, k == body_len && !has_file)
	h.send_win -= k
	if k == body_len && !has_file {
		return true
	}
	// held back: the rest waits on a stream, sent by h2_pump
	i := h.take(id, send_win - k)
	mut s := &h.streams[i]
	unsafe { s.out.push_many(&u8(out.data) + p + k, body_len - k) }
	h.held += body_len - k
	if has_file {
		s.file_fd = file_fd
		s.file_off = file_off
		s.file_left = file_left
		h.files++
	}
	s.sending = true
	h.sending++
	h.sent++ // the stall timeout starts now (see Loop.h2_deadline)
	return true
}

// h2_index is how a response field enters the compression tables. Values that
// change with every response stay out, so they do not push out the ones that repeat;
// Date changes once a second and Content-Length repeats for answers of one size, so
// both go in.
fn h2_index(name string) http2.Index {
	return match name.len {
		4 {
			if eq_lower(name, 'etag') {
				http2.Index.without
			} else {
				http2.Index.incremental
			}
		}
		8 {
			if eq_lower(name, 'location') {
				http2.Index.without
			} else {
				http2.Index.incremental
			}
		}
		10 {
			if eq_lower(name, 'set-cookie') {
				http2.Index.never
			} else {
				http2.Index.incremental
			}
		}
		13 {
			if eq_lower(name, 'last-modified') || eq_lower(name, 'content-range') {
				http2.Index.without
			} else {
				http2.Index.incremental
			}
		}
		else {
			http2.Index.incremental
		}
	}
}

// sendable is how much of n bytes the connection window and a stream window of
// stream_win let go now.
fn (h &H2Conn) sendable(n i64, stream_win i64) int {
	mut k := n
	if k > h.send_win {
		k = h.send_win
	}
	if k > stream_win {
		k = stream_win
	}
	return if k < 0 { 0 } else { int(k) }
}

// h2_hop_by_hop is whether an HTTP/1.1 response field has no place in HTTP/2
// (RFC 9113 8.2.2).
fn h2_hop_by_hop(name string) bool {
	return match name.len {
		7 { eq_lower(name, 'upgrade') }
		10 { eq_lower(name, 'connection') || eq_lower(name, 'keep-alive') }
		16 { eq_lower(name, 'proxy-connection') }
		17 { eq_lower(name, 'transfer-encoding') }
		else { false }
	}
}

// eq_lower is whether s equals the lowercase t, ignoring ASCII case in s.
fn eq_lower(s string, t string) bool {
	if s.len != t.len {
		return false
	}
	for k in 0 .. s.len {
		if http1.lower(s[k]) != t[k] {
			return false
		}
	}
	return true
}

// h2_headers_frames appends block as a HEADERS frame and CONTINUATION frames past
// the frame size, END_STREAM on the HEADERS when end is set.
fn h2_headers_frames(mut out []u8, id u32, block []u8, end bool) {
	mut off := 0
	for {
		n := if block.len - off > http2.default_frame_size {
			http2.default_frame_size
		} else {
			block.len - off
		}
		last := off + n == block.len
		mut flags := if last { http2.flag_end_headers } else { u8(0) }
		typ := if off == 0 { http2.frame_headers } else { http2.frame_continuation }
		if off == 0 && end {
			flags |= http2.flag_end_stream
		}
		http2.write_frame_header(mut out, n, typ, flags, id)
		unsafe { out.push_many(&u8(block.data) + off, n) }
		off += n
		if last {
			return
		}
	}
}

// h2_data_frames appends n bytes at p as DATA frames on stream id, END_STREAM on the
// last when end is set.
fn h2_data_frames(mut out []u8, id u32, p &u8, n int, end bool) {
	if n == 0 {
		if end {
			http2.write_frame_header(mut out, 0, http2.frame_data, http2.flag_end_stream, id)
		}
		return
	}
	mut off := 0
	for off < n {
		k := if n - off > http2.default_frame_size { http2.default_frame_size } else { n - off }
		flags := if end && off + k == n { http2.flag_end_stream } else { u8(0) }
		http2.write_frame_header(mut out, k, http2.frame_data, flags, id)
		unsafe { out.push_many(p + off, k) }
		off += k
	}
}

// h2_pump sends what flow control held back, as far as the windows and h2_pump_max
// allow, a frame per stream in turn so one large answer does not hold up the rest;
// true when it added to c.wbuf.
fn (mut w Worker) h2_pump(mut c Conn) bool {
	mut h := c.h2
	if h.sending == 0 || c.close_after {
		return false
	}
	start := c.wbuf.len
	n := h.streams.len
	h.pump_next = (h.pump_next + 1) % n
	mut moved := true
	for moved && h.sending > 0 && h.send_win > 0 && c.wbuf.len < h2_pump_max {
		moved = false
		for j in 0 .. n {
			i := (h.pump_next + j) % n
			if h.streams[i].sending && w.h2_pump_frame(mut c, i) {
				moved = true
			}
			if h.send_win <= 0 || c.wbuf.len >= h2_pump_max {
				h.pump_next = (i + 1) % n
				break
			}
		}
	}
	return c.wbuf.len > start
}

// h2_pump_frame sends one DATA frame of what stream i holds back, if its window
// allows; false when it could send nothing.
fn (mut w Worker) h2_pump_frame(mut c Conn, i int) bool {
	mut h := c.h2
	mut s := &h.streams[i]
	if s.out_off < s.out.len {
		n := s.out.len - s.out_off
		mut k := h.sendable(n, s.send_win)
		if k > http2.default_frame_size {
			k = http2.default_frame_size
		}
		if k == 0 {
			return false
		}
		// a stream still being written keeps its slot once what it wrote is out
		end := k == n && s.file_left == 0 && isnil(s.st)
		h2_data_frames(mut c.wbuf, s.id, unsafe { &u8(s.out.data) + s.out_off }, k, end)
		s.out_off += k
		s.send_win -= k
		h.send_win -= k
		h.held -= k
		h.sent += u64(k)
		if end {
			h.release(i)
		} else if k == n && !isnil(s.st) {
			s.sending = false
			h.sending--
			unsafe {
				s.out.len = 0
			}
			s.out_off = 0
		}
		return true
	}
	if s.file_left == 0 {
		return false
	}
	mut k := h.sendable(s.file_left, s.send_win)
	if k > http2.default_frame_size {
		k = http2.default_frame_size
	}
	if k == 0 {
		return false
	}
	if c.wbuf.cap - c.wbuf.len < http2.frame_header_len + k {
		unsafe { c.wbuf.grow_cap(http2.frame_header_len + k) } // cold: the first file on this connection
	}
	end := i64(k) == s.file_left
	http2.write_frame_header(mut c.wbuf, k, http2.frame_data, if end {
		http2.flag_end_stream
	} else {
		u8(0)
	}, s.id)
	got := http1.read_at(s.file_fd, unsafe { &u8(c.wbuf.data) + c.wbuf.len }, k, s.file_off)
	if got != k {
		// the file shrank: the promised length cannot be kept
		unsafe {
			c.wbuf.len -= http2.frame_header_len
		}
		w.h2_reset(mut c, s.id, http2.err_internal)
		return true
	}
	unsafe {
		c.wbuf.len += k
	}
	s.file_off += k
	s.file_left -= k
	s.send_win -= k
	h.send_win -= k
	h.sent += u64(k)
	if end {
		h.release(i)
	}
	return true
}

fn (mut w Worker) h2_on_settings(mut c Conn, fh http2.FrameHeader, payload []u8) {
	mut h := c.h2
	if fh.stream != 0 {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	if fh.flags & http2.flag_ack != 0 {
		if fh.length != 0 {
			w.h2_fail(mut c, http2.err_frame_size)
		}
		h.flood++ // we send one SETTINGS; every ACK past its answer is noise
		return
	}
	if fh.length % 6 != 0 {
		w.h2_fail(mut c, http2.err_frame_size)
		return
	}
	if h.settings {
		h.flood++
	}
	h.settings = true
	for k := 0; k < payload.len; k += 6 {
		id := int(u32(payload[k]) << 8 | u32(payload[k + 1]))
		v := unsafe { http2.get_u32(&u8(payload.data) + k + 2) }
		if id == http2.settings_header_table_size {
			h.enc.set_limit(if v > u32(http2.default_table_size) {
				http2.default_table_size
			} else {
				int(v)
			})
		} else if id == http2.settings_enable_push {
			if v > 1 {
				w.h2_fail(mut c, http2.err_protocol)
				return
			}
		} else if id == http2.settings_initial_window_size {
			if v > u32(http2.max_window) {
				w.h2_fail(mut c, http2.err_flow_control)
				return
			}
			// every stream's window moves by the change (RFC 9113 6.9.2)
			delta := i64(v) - h.peer_window
			h.peer_window = i64(v)
			for mut s in h.streams {
				if s.id != 0 {
					s.send_win += delta
					if s.send_win > http2.max_window {
						w.h2_fail(mut c, http2.err_flow_control)
						return
					}
				}
			}
		} else if id == http2.settings_max_frame_size {
			// we send frames of at most the default size, which is always allowed
			if v < u32(http2.default_frame_size) || v > u32(http2.max_frame_size) {
				w.h2_fail(mut c, http2.err_protocol)
				return
			}
		}
		// MAX_CONCURRENT_STREAMS limits pushes, which we never make; the rest are
		// advisory or unknown
	}
	http2.write_frame_header(mut c.wbuf, 0, http2.frame_settings, http2.flag_ack, 0)
	w.h2_pump(mut c)
}

fn (mut w Worker) h2_on_ping(mut c Conn, fh http2.FrameHeader, payload []u8) {
	if fh.stream != 0 {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	if fh.length != 8 {
		w.h2_fail(mut c, http2.err_frame_size)
		return
	}
	c.h2.flood++ // a PING either way: we never send one, so an ACK answers nothing
	if fh.flags & http2.flag_ack != 0 {
		return
	}
	http2.write_frame_header(mut c.wbuf, 8, http2.frame_ping, http2.flag_ack, 0)
	unsafe { c.wbuf.push_many(payload.data, 8) }
}

fn (mut w Worker) h2_on_window_update(mut c Conn, fh http2.FrameHeader, payload []u8) {
	mut h := c.h2
	if fh.length != 4 {
		w.h2_fail(mut c, http2.err_frame_size)
		return
	}
	inc := i64(unsafe { http2.get_u32(&u8(payload.data)) } & 0x7fffffff)
	if fh.stream == 0 {
		if inc == 0 {
			w.h2_fail(mut c, http2.err_protocol)
			return
		}
		h.send_win += inc
		if h.send_win > http2.max_window {
			w.h2_fail(mut c, http2.err_flow_control)
			return
		}
	} else {
		i := h.find(fh.stream)
		if i < 0 {
			if fh.stream > h.last_id {
				w.h2_fail(mut c, http2.err_protocol) // a stream never opened
			}
			h.flood++ // a closed stream: nothing to move
			return
		}
		if inc == 0 {
			w.h2_reset(mut c, fh.stream, http2.err_protocol)
			return
		}
		h.streams[i].send_win += inc
		if h.streams[i].send_win > http2.max_window {
			w.h2_reset(mut c, fh.stream, http2.err_flow_control)
			return
		}
	}
	w.h2_pump(mut c)
}

fn (mut w Worker) h2_on_rst(mut c Conn, fh http2.FrameHeader) {
	mut h := c.h2
	if fh.stream == 0 {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	if fh.length != 4 {
		w.h2_fail(mut c, http2.err_frame_size)
		return
	}
	if fh.stream > h.last_id {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	h.flood++
	i := h.find(fh.stream)
	if i >= 0 {
		w.h2_st_end(mut c, i) // a stream the client cancels ends like one whose client went away
		h.release(i)
		w.h2_credit_all(mut c)
	}
}

fn (mut w Worker) h2_on_priority(mut c Conn, fh http2.FrameHeader, payload []u8) {
	if fh.stream == 0 {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	c.h2.flood++ // priorities are not acted on (RFC 9113 5.3.2)
	if fh.length != 5 {
		w.h2_reset(mut c, fh.stream, http2.err_frame_size)
		return
	}
	if unsafe { http2.get_u32(&u8(payload.data)) } & 0x7fffffff == fh.stream {
		w.h2_reset(mut c, fh.stream, http2.err_protocol) // depending on itself (RFC 9113 5.3.1)
	}
}

// h2_on_goaway: the client will open no more streams. The connection stays until it
// closes it: what is in progress still gets its answer, and closing now, with frames
// it sent after the GOAWAY unread, would reset the connection.
fn (mut w Worker) h2_on_goaway(mut c Conn, fh http2.FrameHeader) {
	if fh.stream != 0 {
		w.h2_fail(mut c, http2.err_protocol)
		return
	}
	c.h2.flood++ // one is a notice; a stream of them is not
}
