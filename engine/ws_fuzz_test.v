module engine

import os
import rand
import viltrum.http1
import viltrum.router

// Mutation fuzzer for the WebSocket frame reader (ws_process), in the style of
// http1/fuzz_test.v: valid client frames, mutated, fed in one to three reads.

fn fuzz_echo(mut s http1.Ws, m http1.WsMessage) {
	if m.binary {
		s.send_binary(m.data)
	} else {
		s.send_text(m.text())
	}
}

fn fuzz_up(h &http1.WsHandler) http1.Handler {
	return fn [h] (mut c http1.Ctx) {
		c.ws_upgrade(h)
	}
}

// fuzz_worker serves /ws (1 MiB messages) and /small (100 bytes), both echoing.
fn fuzz_worker() &Worker {
	mut r := &router.Router{}
	r.add(.get, '/ws', [fuzz_up(&http1.WsHandler{ on_message: fuzz_echo })]) or { panic(err) }
	r.add(.get, '/small', [
		fuzz_up(&http1.WsHandler{ on_message: fuzz_echo, max_message: 100 }),
	]) or { panic(err) }
	return new_worker(r, Options{ send_date: false }, 0)
}

fn fuzz_feed(mut w Worker, mut c Conn, b []u8) {
	unsafe { c.rbuf.push_many(b.data, b.len) }
	for {
		before := c.rbuf.len
		w.process(mut c)
		if c.close_after || c.rbuf.len == 0 || c.rbuf.len == before {
			break
		}
	}
}

// upgrade resets c and upgrades it on path, with the 101 already taken out of wbuf.
fn upgrade(mut w Worker, mut c Conn, path string) {
	c.reset(3)
	fuzz_feed(mut w, mut c,
		'GET ${path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'.bytes())
	assert !isnil(c.ws) && c.wbuf.bytestr().starts_with('HTTP/1.1 101 ')
	unsafe {
		c.wbuf.len = 0
	}
}

fn fuzz_frame(op u8, fin bool, payload []u8) []u8 {
	mask := [u8(0x5a), 0x01, 0xc3, 0x7e]
	mut out := [u8((if fin { 0x80 } else { 0 }) | op)]
	n := payload.len
	if n < 126 {
		out << u8(0x80 | n)
	} else if n < 65536 {
		out << [u8(0x80 | 126), u8(n >> 8), u8(n)]
	} else {
		out << u8(0x80 | 127)
		for i in 0 .. 8 {
			out << u8(u64(n) >> (56 - 8 * i))
		}
	}
	out << mask
	for i, b in payload {
		out << b ^ mask[i & 3]
	}
	return out
}

// frame_size is the length of the frame at the start of b, 0 when its header is not
// all there yet. It trusts the length field and checks nothing else.
fn frame_size(b []u8) u64 {
	if b.len < 2 {
		return 0
	}
	n := u64(b[1] & 0x7f)
	if n < 126 {
		return if b.len < 6 { u64(0) } else { 6 + n }
	}
	if n == 126 {
		return if b.len < 8 { u64(0) } else { 8 + (u64(b[2]) << 8 | u64(b[3])) }
	}
	if b.len < 14 {
		return 0
	}
	mut m := u64(0)
	for i in 2 .. 10 {
		m = m << 8 | u64(b[i])
	}
	return 14 + m
}

// server_frames checks that b is whole, unmasked server frames and returns them as
// (opcode, payload) pairs.
fn server_frames(b []u8) []SFrameF {
	mut out := []SFrameF{}
	mut i := 0
	for i < b.len {
		assert b.len - i >= 2, b.hex()
		assert b[i + 1] & 0x80 == 0, 'server frames are not masked'
		mut n := u64(b[i + 1] & 0x7f)
		mut h := 2
		if n == 126 {
			assert b.len - i >= 4
			n = u64(b[i + 2]) << 8 | u64(b[i + 3])
			h = 4
		} else if n == 127 {
			assert b.len - i >= 10
			n = 0
			for k in 2 .. 10 {
				n = n << 8 | u64(b[i + k])
			}
			h = 10
		}
		assert u64(b.len - i - h) >= n, 'truncated server frame'
		out << SFrameF{
			op:   b[i] & 0x0f
			data: b[i + h..i + h + int(n)]
		}
		i += h + int(n)
	}
	return out
}

struct SFrameF {
	op   u8
	data []u8
}

const ws_fuzz_tokens = [[u8(0x81)], [u8(0x82)], [u8(0x80)], [u8(0x01)],
	[u8(0x88)], [u8(0x89)], [u8(0x8a)], [u8(0x7e)], [u8(0x7f)],
	[u8(0xfe)], [u8(0xff)], [u8(0x00)], [u8(0xc3), 0x28], [u8(0xed), 0xa0, 0x80],
	[u8(0xf4), 0x90, 0x80, 0x80], [u8(0x03), 0xe8], [u8(0x03), 0xed],
	[u8(0xff), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]]

fn ws_fuzz_seeds() [][]u8 {
	mut seeds := [][]u8{}
	seeds << fuzz_frame(http1.ws_text, true, 'hello'.bytes())
	seeds << fuzz_frame(http1.ws_binary, true, [u8(0), 1, 2, 0xff])
	seeds << fuzz_frame(http1.ws_text, true, 'caf\xc3\xa9 \xf0\x9f\x98\x80'.bytes())
	seeds << fuzz_frame(http1.ws_text, true, []u8{len: 200, init: `a`})
	mut frag := fuzz_frame(http1.ws_text, false, 'hel'.bytes())
	frag << fuzz_frame(http1.ws_ping, true, 'p'.bytes())
	frag << fuzz_frame(0, true, 'lo'.bytes())
	seeds << frag
	seeds << fuzz_frame(http1.ws_ping, true, 'ping'.bytes())
	seeds << fuzz_frame(http1.ws_pong, true, []u8{})
	seeds << fuzz_frame(http1.ws_close, true, [u8(0x03), 0xe8, `o`, `k`])
	mut two := fuzz_frame(http1.ws_text, true, 'a'.bytes())
	two << fuzz_frame(http1.ws_binary, true, 'b'.bytes())
	seeds << two
	return seeds
}

fn ws_mutate(b []u8) []u8 {
	mut out := b.clone()
	pos := if out.len == 0 { 0 } else { rand.intn(out.len) or { 0 } }
	op := rand.intn(6) or { 0 }
	match op {
		0 {
			if out.len > 0 {
				out[pos] = u8(rand.intn(256) or { 0 })
			}
		}
		1 {
			if out.len > 0 {
				out[pos] ^= u8(1) << u8(rand.intn(8) or { 0 })
			}
		}
		2 {
			if out.len > 0 {
				out.delete(pos)
			}
		}
		3 {
			// a local, not inline: see mutate in http1/fuzz_test.v
			tok := ws_fuzz_tokens[rand.intn(ws_fuzz_tokens.len) or { 0 }]
			out.insert(pos, tok)
		}
		4 {
			end := pos + (rand.intn(16) or { 0 })
			out = out[..pos].clone()
			out << b[if end < b.len { end } else { b.len }..]
		}
		else {
			out = out[..pos].clone()
		}
	}

	return out
}

// Invariants: no panic; the server writes only whole, unmasked frames; a connection
// it fails gets one Close with the code it reports; and while it stays open, what is
// left in rbuf is never a whole frame it should have handled.
fn test_fuzz_ws_frames() {
	iters := os.getenv_opt('VILTRUM_FUZZ_ITERS') or { '20000' }.int()
	rand.seed([u32(0x5eed), 0x4])
	seeds := ws_fuzz_seeds()
	mut w := fuzz_worker()
	mut c := new_conn()
	for _ in 0 .. iters {
		mut b := seeds[rand.intn(seeds.len) or { 0 }].clone()
		for _ in 0 .. 1 + (rand.intn(4) or { 0 }) {
			b = ws_mutate(b)
		}
		path := if rand.intn(2) or { 0 } == 0 { '/ws' } else { '/small' }
		upgrade(mut w, mut c, path)
		mut at := 0
		for at < b.len && !c.close_after {
			step := 1 + (rand.intn(b.len - at) or { 0 })
			fuzz_feed(mut w, mut c, b[at..at + step])
			at += step
		}
		frames := server_frames(c.wbuf)
		if c.close_after {
			closes := frames.filter(it.op == http1.ws_close)
			assert closes.len == 1 && frames.last().op == http1.ws_close, b.hex()
			cl := closes[0].data
			if cl.len >= 2 {
				code := int(u16(cl[0]) << 8 | u16(cl[1]))
				assert code == c.ws_code, b.hex()
				assert http1.ws_valid_close_code(code), b.hex()
			}
		} else {
			for f in frames {
				assert f.op in [http1.ws_text, http1.ws_binary, http1.ws_pong], b.hex()
			}
			size := frame_size(c.rbuf)
			assert size == 0 || size > u64(c.rbuf.len), b.hex()
		}
		w.ws_end(mut c)
	}
}
