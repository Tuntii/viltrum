module engine

import time
import viltrum.http1
import viltrum.http2
import viltrum.router

pub const read_buf_size = 8 * 1024
pub const write_buf_size = 16 * 1024

// buffers one large request or response grew past these are given back when done
const shrink_rbuf_above = 64 * 1024
const shrink_wbuf_above = 256 * 1024

// Conn is one client connection. A worker keeps the Conn after the connection
// closes and reuses it, buffers included, for its next accepted connection.
@[heap]
pub struct Conn {
pub mut:
	fd          int = -1
	rbuf        []u8
	wbuf        []u8
	woff        int // bytes of wbuf already sent
	frame       http1.Frame
	close_after bool
	out_armed   bool // EPOLLOUT registered: output pending, reading paused
	reading     bool // part of a request is buffered
	deadline_ms i64
	counted     bool // holds a max_conns slot
	gen         u32  // per worker, unique per connection, so a stale timer cannot answer a newer one
	waiting     bool // a deferred response is pending; requests behind it wait
	pending     Pending
	tls         &TlsConn = unsafe { nil } // the TLS session while this connection is TLS
	tls_keep    &TlsConn = unsafe { nil } // kept across connections so mbedtls' buffers are reused
	hs_queued   bool // its next handshake step waits in the worker's queue (Loop.next_handshake)
	// HTTP/2, once the connection speaks it (h2.v)
	h2      &H2Conn = unsafe { nil }
	h2_keep &H2Conn = unsafe { nil } // kept across connections, tables and buffers included
	h2_ok   bool // HTTP/2 is allowed and the first bytes may be its preface
	// WebSocket, once the connection is upgraded
	ws         &http1.WsHandler = unsafe { nil }
	ws_data    voidptr
	ws_msg     []u8 // a fragmented message being put back together
	ws_frag    u8   // that message's opcode, 0 when none is in progress
	ws_proto   int
	ws_closing bool     // our Close went out
	ws_code    int      // the code on_close reports
	subs       []&Topic // topics this connection is subscribed to
	touched    bool     // in the worker's list of connections to flush
	// a file answer being streamed after wbuf: the open file, where it is, what is left
	file_fd   int = -1
	file_off  i64
	file_left i64
	// closing: the client may still be sending (a refused request, input dropped
	// behind a close), so the engine drains it before closing (Loop.linger)
	linger     bool
	lingering  bool
	linger_end i64
}

// Pending is what survives of a request whose response was deferred (Ctx.after).
struct Pending {
mut:
	cb     http1.Resume = unsafe { nil }
	arg    u64
	method http1.Method
	minor  int
	close  bool
	due    u64 // time.sys_mono_now() ns
}

pub fn new_conn() &Conn {
	return &Conn{
		rbuf: []u8{cap: read_buf_size}
		wbuf: []u8{cap: write_buf_size}
	}
}

// reset prepares a reused Conn for a new connection on fd.
pub fn (mut c Conn) reset(fd int) {
	c.fd = fd
	unsafe {
		c.rbuf.len = 0
		c.wbuf.len = 0
	}
	c.woff = 0
	c.frame.reset()
	c.close_after = false
	c.out_armed = false
	c.reading = false
	c.counted = false
	c.waiting = false
	c.tls = unsafe { nil }
	c.hs_queued = false
	c.h2 = unsafe { nil }
	c.h2_ok = false
	c.ws = unsafe { nil }
	c.ws_data = unsafe { nil }
	unsafe {
		c.ws_msg.len = 0
	}
	c.ws_frag = 0
	c.ws_closing = false
	c.ws_code = 0
	c.linger = false
	c.lingering = false
}

// Worker serves the requests of one event loop. It owns the Ctx, the Date cache
// and the gzip state, so requests share nothing across threads.
@[heap]
pub struct Worker {
pub mut:
	ctx      http1.Ctx
	r        &router.Router
	opts     Options
	m        router.Match
	requests u64
	timers   Timers // deferred responses, earliest first
	gen      u32    // last Conn.gen handed out
	ws       http1.Ws
	hub      &Hub = unsafe { nil } // where publish and send go; nil drops them (handle_raw)
	topics   map[string]&Topic // this worker's subscribers per topic
	// HTTP/2 scratch (h2.v), sized on the first HTTP/2 connection: decoded fields, the
	// request as an HTTP/1.1 head and its body, the response the handler wrote, and
	// its header block
	h2dec  []u8
	h2fs   http2.Fields
	h2req  []u8
	h2body []u8
	h2out  []u8
	h2blk  []u8
}

pub fn new_worker(r &router.Router, opts Options, index int) &Worker {
	mut w := &Worker{
		ctx:  http1.Ctx.new()
		r:    r
		opts: opts
	}
	w.ctx.send_date = opts.send_date
	w.ctx.server = opts.server_header
	w.ctx.deflater = http1.new_deflater()
	w.ctx.worker = index
	w.ws.worker = index
	return w
}

// is_http10 reports whether the request line at buf[off..] ends in HTTP/1.0; HTTP/1.0
// clients do not understand 100 Continue.
fn is_http10(buf []u8, off int) bool {
	mut i := off
	for i < buf.len && buf[i] != `\r` {
		i++
	}
	return i > off && i < buf.len && buf[i - 1] == `0`
}

// process serves every complete request buffered in c.rbuf, appending responses to
// c.wbuf, and compacts what is left. It never touches the socket.
pub fn (mut w Worker) process(mut c Conn) {
	if !isnil(c.ws) {
		w.ws_process(mut c)
		return
	}
	if !isnil(c.h2) {
		w.h2_process(mut c)
		return
	}
	if c.h2_ok {
		// the first bytes on a listener that also speaks HTTP/2 with prior knowledge
		match h2_preface_state(c.rbuf) {
			1 {
				w.h2_open(mut c)
				w.h2_process(mut c)
				return
			}
			0 {
				c.reading = true // a preface cut short runs under the read timeout
				return
			}
			-2 {
				// an HTTP/2 preface gone wrong (RFC 9113 3.4)
				w.h2_open(mut c)
				w.h2_fail(mut c, http2.err_protocol)
				return
			}
			else {
				c.h2_ok = false
			}
		}
	}
	mut off := 0
	for !c.close_after && !c.waiting && c.file_fd < 0 && off < c.rbuf.len
		&& c.wbuf.len < w.opts.max_pending {
		if c.frame.head_end == 0 {
			// empty lines before a request line are ignored (RFC 9112 2.2): some
			// clients send a CRLF after a POST body
			for off + 1 < c.rbuf.len && c.rbuf[off] == `\r` && c.rbuf[off + 1] == `\n` {
				off += 2
			}
			if off == c.rbuf.len {
				break
			}
		}
		msg := http1.view(c.rbuf, off, c.rbuf.len - off)
		n := http1.frame(msg, mut c.frame, w.opts.limits) or {
			w.refuse(mut c, err)
			off = c.rbuf.len
			break
		}
		if n < 0 {
			if c.frame.expect_continue && !c.frame.continue_sent && !is_http10(c.rbuf, off) {
				http1.append_str(mut c.wbuf, 'HTTP/1.1 100 Continue\r\n\r\n')
				c.frame.continue_sent = true
			}
			break
		}
		w.serve(mut c, http1.view(msg, 0, n))
		off += n
		c.frame.reset()
		if !isnil(c.ws) {
			break // what follows the upgrade is WebSocket frames
		}
	}
	if c.close_after {
		c.linger = c.linger || off < c.rbuf.len
		off = c.rbuf.len
	}
	c.reading = off < c.rbuf.len && isnil(c.ws)
	if off > 0 {
		rest := c.rbuf.len - off
		if rest > 0 {
			unsafe { C.memmove(c.rbuf.data, &u8(c.rbuf.data) + off, rest) }
		}
		unsafe {
			c.rbuf.len = rest
		}
	}
}

fn (mut w Worker) serve(mut c Conn, msg []u8) {
	mut x := &w.ctx
	http1.parse_head(msg, c.frame.head_end, mut x.head) or {
		w.refuse(mut c, err)
		return
	}
	if w.opts.require_host && x.head.minor == 1 && !x.head.host_seen {
		w.refuse(mut c, http1.HttpError{
			status: 400
			reason: 'missing host header'
		})
		return
	}
	x.out = c.wbuf
	x.begin(msg)
	if c.frame.chunked {
		x.set_chunked_body(c.frame.head_end)
	} else {
		x.set_body(http1.view(msg, c.frame.head_end, c.frame.content_length))
	}
	idx := w.run_chain(mut x)
	w.finish(mut c, idx)
	w.requests++
	$if viltrum_debug ? {
		// Poison the request so a handler that kept a view reads garbage in tests.
		unsafe { C.memset(msg.data, 0xA5, msg.len) }
	}
}

// run_chain routes the request in x and runs its chain; the route lookup's result
// (an index, or router.not_found / method_not_allowed) picks the default answer.
fn (mut w Worker) run_chain(mut x http1.Ctx) int {
	idx := w.r.find(x.head.method, x.path(), mut w.m)
	if idx >= 0 {
		x.chain = w.r.routes[idx].chain
		x.param_names = w.r.routes[idx].param_names
		x.nparams = w.m.n
		for k in 0 .. w.m.n {
			x.params[k] = http1.Span{
				start: x.head.path.start + w.m.spans[k].start
				len:   w.m.spans[k].len
			}
		}
	} else if idx == router.method_not_allowed {
		x.chain = w.r.on_405
		x.allow = w.r.allowed(x.path())
	} else {
		x.chain = w.r.on_404
	}
	if x.chain.len > 0 {
		x.chain[0](mut x)
	}
	return idx
}

// resume writes the response deferred on c; the caller then serves what was
// pipelined behind it (process).
pub fn (mut w Worker) resume(mut c Conn) {
	c.waiting = false
	mut x := &w.ctx
	x.out = c.wbuf
	x.begin_resumed(c.pending.method, c.pending.minor, !c.pending.close)
	c.pending.cb(mut x, c.pending.arg)
	w.finish(mut c, 0)
}

// process_waiting is process that sleeps out deferred responses in place. For
// handle_raw and tests only: the event loop never blocks a worker like this.
pub fn (mut w Worker) process_waiting(mut c Conn) {
	for {
		before := c.rbuf.len
		w.process(mut c)
		for c.waiting || c.file_fd >= 0 {
			if c.file_fd >= 0 {
				w.inline_file(mut c)
			} else {
				// a sleep can end early (Windows rounds it down to whole milliseconds)
				for {
					now := time.sys_mono_now()
					if now >= c.pending.due {
						break
					}
					time.sleep(time.Duration(i64(c.pending.due - now)))
				}
				w.resume(mut c)
			}
			w.process(mut c)
		}
		// after an upgrade the rest of the input is WebSocket frames
		if c.close_after || c.rbuf.len == 0 || c.rbuf.len == before {
			break
		}
	}
	w.timers = Timers{}
}

// inline_file appends what is left of a streamed file to wbuf, for process_waiting:
// handle_raw and tests have no socket to stream it to.
fn (mut w Worker) inline_file(mut c Conn) {
	n := c.file_left
	if c.wbuf.cap - c.wbuf.len < n {
		unsafe { c.wbuf.grow_cap(int(n)) } // cold: tests only
	}
	got := http1.read_at(c.file_fd, unsafe { &u8(c.wbuf.data) + c.wbuf.len }, n, c.file_off)
	if got > 0 {
		unsafe {
			c.wbuf.len += int(got)
		}
	}
	c.end_file()
	if got != n {
		c.close_after = true // the head promised more than the file has now
	}
}

// end_file closes the file being streamed, if any.
pub fn (mut c Conn) end_file() {
	if c.file_fd >= 0 {
		http1.close_file(c.file_fd)
		c.file_fd = -1
	}
	c.file_left = 0
}

// finish takes the Ctx's response, or its deferral, back into c. idx is the route
// lookup result, which picks the answer for a handler that wrote nothing.
fn (mut w Worker) finish(mut c Conn, idx int) {
	mut x := &w.ctx
	if x.deferred {
		// the connection stays open until the deferred response is out
		c.waiting = true
		c.pending.cb = x.defer_cb
		c.pending.arg = x.defer_arg
		c.pending.method = x.head.method
		c.pending.minor = x.head.minor
		c.pending.close = x.close_after
		c.pending.due = time.sys_mono_now() + u64(x.defer_ms) * 1_000_000
		w.timers.push(c.pending.due, c.fd, c.gen)
		c.wbuf = x.out
		return
	}
	w.answer_default(idx)
	c.wbuf = x.out
	c.close_after = x.close_after
	if x.file_fd >= 0 {
		// the head is in wbuf; the engine sends the file after it
		c.file_fd = x.file_fd
		c.file_off = x.file_off
		c.file_left = x.file_left
		x.file_fd = -1
	}
	if !isnil(x.ws) && x.status == 101 && !c.close_after {
		w.ws_open(mut c)
	}
}

// answer_default answers a request whose chain wrote no response: 404 or 405 when
// no route took it, 500 (and close) when one did and wrote nothing.
fn (mut w Worker) answer_default(idx int) {
	mut x := &w.ctx
	if x.responded {
		return
	}
	if idx == router.not_found {
		x.text(404, 'not found')
	} else if idx == router.method_not_allowed {
		x.set_allow()
		x.text(405, 'method not allowed')
	} else {
		x.close()
		x.text(500, 'internal error')
	}
}

// refuse answers a framing or parse error after any earlier pipelined responses and
// marks the connection to close.
fn (mut w Worker) refuse(mut c Conn, err IError) {
	status := if err.code() >= 400 { err.code() } else { 400 }
	mut x := &w.ctx
	x.head.method = .get
	x.head.minor = 1
	x.head.keep_alive = false
	x.out = c.wbuf
	x.begin(http1.view(c.rbuf, 0, 0))
	x.text(status, err.msg())
	c.wbuf = x.out
	c.close_after = true
	c.linger = true // the rest of the request may still be on its way
}
