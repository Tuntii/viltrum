module engine

import viltrum.http1

// WebSocket connections on the worker: after the 101 the same Conn reads frames
// instead of requests. Frames are unmasked in place and a message that came in one
// frame reaches the handler as a view into the read buffer; only a fragmented one is
// copied, into a buffer the Conn keeps. Sends append to the write buffer, which the
// event loop flushes as it does responses.

// ws_open takes the connection over after the upgrade response; the Ctx still holds
// the upgrade request for on_open.
fn (mut w Worker) ws_open(mut c Conn) {
	c.ws = w.ctx.ws
	c.ws_proto = w.ctx.ws_proto
	c.ws_data = unsafe { nil }
	c.ws_frag = 0
	c.ws_closing = false
	c.ws_code = 1006 // until a Close says otherwise
	c.reading = false
	if !isnil(c.ws.on_open) {
		mut s := w.ws_lend(mut c)
		c.ws.on_open(mut s, mut w.ctx)
		w.ws_take(mut c)
	}
}

// ws_process handles every whole frame buffered in c.rbuf and compacts what is left
// (the start of the next frame).
pub fn (mut w Worker) ws_process(mut c Conn) {
	mut off := 0
	for !c.close_after && c.wbuf.len < w.opts.max_pending {
		avail := c.rbuf.len - off
		if avail < 2 {
			break
		}
		p := unsafe { &u8(c.rbuf.data) + off }
		b0 := unsafe { p[0] }
		b1 := unsafe { p[1] }
		op := b0 & 0x0f
		fin := b0 & 0x80 != 0
		control := op & 0x08 != 0
		mut n := u64(b1 & 0x7f)
		// no extension is negotiated, so RSV bits are errors; clients must mask
		if b0 & 0x70 != 0 || b1 & 0x80 == 0 || !(op <= 2 || (op >= 8 && op <= 10))
			|| (control && (!fin || n > 125)) {
			w.ws_fail(mut c, 1002, 'protocol error')
			break
		}
		hl := if n == 126 {
			4
		} else if n == 127 {
			10
		} else {
			2
		}
		if avail < hl + 4 {
			break
		}
		if hl == 4 {
			n = u64(unsafe { p[2] }) << 8 | u64(unsafe { p[3] })
		} else if hl == 10 {
			n = 0
			for i in 2 .. 10 {
				n = n << 8 | u64(unsafe { p[i] })
			}
		}
		room := u64(c.ws.max_message) - u64(if op == 0 { c.ws_msg.len } else { 0 })
		if !control && n > room {
			w.ws_fail(mut c, 1009, 'message too big')
			break
		}
		total := hl + 4 + int(n)
		if avail < total {
			break // the event loop grows rbuf up to max_message
		}
		data := unsafe { p + hl + 4 }
		http1.ws_unmask(data, int(n), unsafe { p + hl })
		off += total
		match op {
			http1.ws_text, http1.ws_binary {
				if c.ws_frag != 0 {
					w.ws_fail(mut c, 1002, 'expected continuation')
					break
				}
				if fin {
					w.ws_deliver(mut c, op, http1.view(c.rbuf, off - int(n), int(n)))
				} else {
					c.ws_frag = op
					unsafe {
						c.ws_msg.len = 0
						c.ws_msg.push_many(data, int(n)) // cold: fragmented messages only
					}
				}
			}
			0 {
				if c.ws_frag == 0 {
					w.ws_fail(mut c, 1002, 'unexpected continuation')
					break
				}
				unsafe { c.ws_msg.push_many(data, int(n)) } // cold: fragmented messages only
				if fin {
					kind := c.ws_frag
					c.ws_frag = 0
					w.ws_deliver(mut c, kind, http1.view(c.ws_msg, 0, c.ws_msg.len))
					unsafe {
						c.ws_msg.len = 0
					}
				}
			}
			http1.ws_ping {
				if !c.ws_closing {
					http1.ws_frame(mut c.wbuf, http1.ws_pong, data, int(n))
				}
			}
			http1.ws_close {
				w.ws_peer_close(mut c, data, int(n))
			}
			else {} // pong
		}
	}
	if c.close_after {
		off = c.rbuf.len
	}
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

// ws_deliver hands one whole message to on_message; text must be valid UTF-8.
fn (mut w Worker) ws_deliver(mut c Conn, op u8, data []u8) {
	if op == http1.ws_text && !http1.valid_utf8(data.data, data.len) {
		w.ws_fail(mut c, 1007, 'invalid utf-8')
		return
	}
	if c.ws_closing || isnil(c.ws.on_message) {
		return
	}
	mut s := w.ws_lend(mut c)
	c.ws.on_message(mut s, http1.WsMessage{
		binary: op == http1.ws_binary
		data:   data
	})
	w.ws_take(mut c)
}

// ws_peer_close answers the client's Close (unless ours went out first) and closes
// the connection once the answer is sent.
fn (mut w Worker) ws_peer_close(mut c Conn, data &u8, n int) {
	mut code := 1005 // no status
	if n >= 2 {
		code = int(u16(unsafe { data[0] }) << 8 | u16(unsafe { data[1] }))
	}
	if n == 1 || (n >= 2 && !http1.ws_valid_close_code(code)) {
		w.ws_fail(mut c, 1002, 'bad close code')
		return
	}
	if n > 2 && !http1.valid_utf8(unsafe { data + 2 }, n - 2) {
		w.ws_fail(mut c, 1007, 'invalid utf-8')
		return
	}
	if !c.ws_closing {
		http1.ws_close_frame(mut c.wbuf, if n >= 2 { code } else { 0 }, '')
		c.ws_closing = true
	}
	c.ws_code = code
	c.close_after = true
}

// ws_fail sends a Close with code and closes the connection once it is out.
fn (mut w Worker) ws_fail(mut c Conn, code int, reason string) {
	if !c.ws_closing {
		http1.ws_close_frame(mut c.wbuf, code, reason)
		c.ws_closing = true
	}
	c.ws_code = code
	c.close_after = true
}

// ws_end runs on_close as the connection goes away, once, with the code of the Close
// that ended it (1006 when none did). Sends from on_close are dropped.
pub fn (mut w Worker) ws_end(mut c Conn) {
	h := c.ws
	if isnil(h) {
		return
	}
	c.ws_closing = true
	if !isnil(h.on_close) {
		mut s := w.ws_lend(mut c)
		h.on_close(mut s, c.ws_code)
		w.ws_take(mut c)
	}
	c.ws = unsafe { nil }
	c.ws_data = unsafe { nil }
}

// ws_lend points the worker's Ws at c for one callback.
fn (mut w Worker) ws_lend(mut c Conn) &http1.Ws {
	mut s := &w.ws
	s.out = c.wbuf
	s.data = c.ws_data
	s.closing = c.ws_closing
	s.h = c.ws
	s.proto = c.ws_proto
	return s
}

// ws_take takes back what a callback changed. A close() in it waits for the
// client's Close, under the read timeout.
fn (mut w Worker) ws_take(mut c Conn) {
	c.wbuf = w.ws.out
	c.ws_data = w.ws.data
	if w.ws.closing && !c.ws_closing {
		c.ws_closing = true
		c.ws_code = 1000
	}
}
