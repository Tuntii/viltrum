module http1

import time

// WebSocket (RFC 6455) on the HTTP/1.1 engine: the upgrade handshake and what reading
// and writing frames needs. The engine reads frames on the worker that served the
// upgrade and calls the route's WsHandler there; nothing here allocates per message.

pub const ws_text = u8(0x1)
pub const ws_binary = u8(0x2)
pub const ws_close = u8(0x8)
pub const ws_ping = u8(0x9)
pub const ws_pong = u8(0xa)

const ws_guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
const b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

pub type WsOpen = fn (mut s Ws, mut c Ctx)

pub type WsOnMessage = fn (mut s Ws, m WsMessage)

pub type WsOnClose = fn (mut s Ws, code int)

pub type WsOrigin = fn (origin string) bool

// WsHandler is what a WebSocket route does; see viltrum.WsHandler.
@[heap]
pub struct WsHandler {
pub:
	on_open      WsOpen        = unsafe { nil }
	on_message   WsOnMessage   = unsafe { nil }
	on_close     WsOnClose     = unsafe { nil }
	max_message  int           = 1024 * 1024
	idle_timeout time.Duration = 120 * time.second
	protocols    []string
	check_origin WsOrigin = unsafe { nil }
}

// WsMessage is one whole message. data points into connection buffers and is valid
// only until the callback returns; clone it to keep it.
pub struct WsMessage {
pub:
	binary bool
	data   []u8
}

// text is the message as a string view (valid until the callback returns).
pub fn (m WsMessage) text() string {
	return str_view(m.data, 0, m.data.len)
}

// WsId names one WebSocket connection among all workers (Ws.id), for sending to it
// from elsewhere. It stays unique after the connection closes: sends to it are dropped.
pub struct WsId {
pub:
	worker int
	fd     int = -1
	gen    u32
}

// WsPost is a message on its way to other connections: to a topic's subscribers
// (topic set) or to one connection (to). The engine carries it to the workers.
pub struct WsPost {
pub:
	topic string
	to    WsId
	skip  WsId // the publisher, which does not get its own message
	op    u8
	data  []u8
}

// WsSub is a subscribe (on) or unsubscribe a callback asked for.
pub struct WsSub {
pub:
	topic string
	on    bool
}

// Ws is one WebSocket connection as its callbacks see it. A worker owns a single Ws
// and points it at each connection in turn, like Ctx.
pub struct Ws {
pub mut:
	data voidptr // this connection's own state: set it in on_open, every later callback sees it
	// engine-owned
	out     []u8 // the connection's write buffer, lent for one callback
	closing bool // a Close went out: later sends are dropped
	worker  int
	h       &WsHandler = unsafe { nil }
	proto   int // index into h.protocols, -1 for none
	me      WsId
	posts   []&WsPost // publish calls, carried out when the callback returns
	subs    []WsSub   // subscribe calls, applied when the callback returns
}

// send_text sends one text message. t must be valid UTF-8.
pub fn (mut s Ws) send_text(t string) {
	if !s.closing {
		ws_frame(mut s.out, ws_text, t.str, t.len)
	}
}

pub fn (mut s Ws) send_binary(b []u8) {
	if !s.closing {
		ws_frame(mut s.out, ws_binary, b.data, b.len)
	}
}

// ping sends a Ping; the client answers with a Pong, which the engine absorbs. At
// most 125 bytes of payload are sent.
pub fn (mut s Ws) ping(payload []u8) {
	if !s.closing {
		ws_frame(mut s.out, ws_ping, payload.data,
			if payload.len > 125 { 125 } else { payload.len })
	}
}

// close starts the closing handshake: it sends a Close with code (1000 is normal)
// and reason, after which sends are dropped and messages no longer arrive. The
// connection closes when the client answers, or after the read timeout.
pub fn (mut s Ws) close(code int, reason string) {
	if s.closing {
		return
	}
	s.closing = true
	ws_close_frame(mut s.out, code, reason)
}

pub fn (s &Ws) worker_id() int {
	return s.worker
}

// id names this connection for app.ws_send, from any thread.
pub fn (s &Ws) id() WsId {
	return s.me
}

// subscribe adds this connection to topic: whatever is published to it reaches
// every subscriber, on every worker. A closing connection leaves its topics.
pub fn (mut s Ws) subscribe(topic string) {
	s.subs << WsSub{
		topic: topic.clone() // cold: subscriptions, not messages
		on:    true
	}
}

pub fn (mut s Ws) unsubscribe(topic string) {
	s.subs << WsSub{
		topic: topic.clone() // cold: subscriptions, not messages
	}
}

// publish sends a text message to every subscriber of topic except this connection.
// The message is copied once and goes out after the callback returns.
pub fn (mut s Ws) publish(topic string, t string) {
	s.post(topic, ws_text, t.str, t.len)
}

pub fn (mut s Ws) publish_binary(topic string, b []u8) {
	s.post(topic, ws_binary, b.data, b.len)
}

fn (mut s Ws) post(topic string, op u8, p &u8, n int) {
	if topic.len == 0 {
		return
	}
	s.posts << ws_post(topic, s.me, s.me, op, p, n)
}

// ws_post copies a message for other connections: to a topic, or to one connection
// when topic is ''.
pub fn ws_post(topic string, to WsId, skip WsId, op u8, p &u8, n int) &WsPost {
	mut data := []u8{len: n} // cold: a published message is copied once for all workers
	if n > 0 {
		unsafe { vmemcpy(data.data, p, n) }
	}
	return &WsPost{
		topic: topic.clone() // cold: as above
		to:    to
		skip:  skip
		op:    op
		data:  data
	}
}

// protocol is the subprotocol agreed in the handshake, '' for none.
pub fn (s &Ws) protocol() string {
	if isnil(s.h) || s.proto < 0 {
		return ''
	}
	return s.h.protocols[s.proto]
}

// ws_frame appends one final, unmasked frame (servers do not mask).
pub fn ws_frame(mut out []u8, op u8, p &u8, n int) {
	mut h := [10]u8{}
	h[0] = 0x80 | op
	mut k := 2
	if n < 126 {
		h[1] = u8(n)
	} else if n < 65536 {
		h[1] = 126
		h[2] = u8(n >> 8)
		h[3] = u8(n)
		k = 4
	} else {
		h[1] = 127
		for i in 0 .. 8 {
			h[2 + i] = u8(u64(n) >> (56 - 8 * i))
		}
		k = 10
	}
	unsafe { out.push_many(&h[0], k) }
	if n > 0 {
		unsafe { out.push_many(p, n) }
	}
}

// ws_close_frame appends a Close carrying code and as much of reason as fits (a
// control frame holds 125 bytes). Code 0 sends a Close without a body.
pub fn ws_close_frame(mut out []u8, code int, reason string) {
	mut b := [125]u8{}
	mut n := 0
	if code > 0 {
		b[0] = u8(code >> 8)
		b[1] = u8(code)
		n = 2
		for i in 0 .. reason.len {
			if n == b.len {
				break
			}
			b[n] = reason[i]
			n++
		}
	}
	ws_frame(mut out, ws_close, &b[0], n)
}

// ws_valid_close_code reports whether a peer may send code in a Close (RFC 6455
// 7.4 and the IANA registry; 1005, 1006 and 1015 never go on the wire).
pub fn ws_valid_close_code(code int) bool {
	return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014)
		|| (code >= 3000 && code <= 4999)
}

// ws_unmask XORs p[0..n] with the 4-byte client mask in place, 8 bytes at a time.
pub fn ws_unmask(p &u8, n int, mask &u8) {
	mut m := u64(0)
	unsafe {
		C.memcpy(&m, mask, 4)
		C.memcpy(&u8(&m) + 4, mask, 4)
	}
	mut i := 0
	for i + 8 <= n {
		mut x := u64(0)
		unsafe {
			C.memcpy(&x, p + i, 8)
			x ^= m
			C.memcpy(p + i, &x, 8)
		}
		i += 8
	}
	for i < n {
		unsafe {
			p[i] ^= mask[i & 3]
		}
		i++
	}
}

// valid_utf8 reports whether p[0..n] is well-formed UTF-8 (RFC 3629: no overlong
// forms, no surrogates, nothing past U+10FFFF). ASCII runs go 8 bytes at a time.
pub fn valid_utf8(p &u8, n int) bool {
	mut i := 0
	for i < n {
		if i + 8 <= n {
			mut x := u64(0)
			unsafe { C.memcpy(&x, p + i, 8) }
			if x & 0x8080808080808080 == 0 {
				i += 8
				continue
			}
		}
		c := unsafe { p[i] }
		if c < 0x80 {
			i++
			continue
		}
		mut k := 0
		mut lo := u8(0x80)
		mut hi := u8(0xbf)
		if c >= 0xc2 && c <= 0xdf {
			k = 1
		} else if c >= 0xe0 && c <= 0xef {
			k = 2
			if c == 0xe0 {
				lo = 0xa0 // overlong
			} else if c == 0xed {
				hi = 0x9f // surrogates
			}
		} else if c >= 0xf0 && c <= 0xf4 {
			k = 3
			if c == 0xf0 {
				lo = 0x90 // overlong
			} else if c == 0xf4 {
				hi = 0x8f // past U+10FFFF
			}
		} else {
			return false
		}
		if i + k >= n {
			return false
		}
		c1 := unsafe { p[i + 1] }
		if c1 < lo || c1 > hi {
			return false
		}
		for j in 2 .. k + 1 {
			if unsafe { p[i + j] } & 0xc0 != 0x80 {
				return false
			}
		}
		i += k + 1
	}
	return true
}

// ws_upgrade answers c's request with 101 Switching Protocols and hands the
// connection to h once the response is out, or refuses an invalid upgrade: 426 for
// a plain request or another WebSocket version, 403 for an Origin h rejects, 400
// for anything else wrong.
pub fn (mut c Ctx) ws_upgrade(h &WsHandler) {
	if !c.field_has_token('upgrade', 'websocket') {
		c.set_header('Upgrade', 'websocket')
		c.text(426, 'websocket upgrade required')
		return
	}
	if c.head.minor != 1 || c.close_after || c.head.chunked || c.body_bytes.len > 0
		|| !c.field_has_token('connection', 'upgrade') {
		c.text(400, 'bad websocket upgrade')
		return
	}
	if (c.header('sec-websocket-version') or { '' }) != '13' {
		c.set_header('Sec-WebSocket-Version', '13')
		c.text(426, 'websocket version 13 required')
		return
	}
	key := c.header('sec-websocket-key') or { '' }
	if !valid_ws_key(key) {
		c.text(400, 'bad websocket key')
		return
	}
	if !isnil(h.check_origin) && !h.check_origin(c.header('origin') or { '' }) {
		c.text(403, 'origin not allowed')
		return
	}
	c.ws_proto = -1
	for i, p in h.protocols {
		if c.field_has_token('sec-websocket-protocol', p) {
			c.ws_proto = i
			break
		}
	}
	ws_accept(key, mut c.ws_acc)
	c.set_header('Upgrade', 'websocket')
	c.set_header('Connection', 'Upgrade')
	c.set_header('Sec-WebSocket-Accept', unsafe { tos(&c.ws_acc[0], c.ws_acc.len) })
	if c.ws_proto >= 0 {
		c.set_header('Sec-WebSocket-Protocol', h.protocols[c.ws_proto])
	}
	c.ws = unsafe { h }
	c.no_content(101)
}

// field_has_token reports whether any request field named name lists tok in its
// comma-separated value (both compared without case).
fn (c &Ctx) field_has_token(name string, tok string) bool {
	for k in 0 .. c.head.nfields {
		f := c.head.fields[k]
		if !eq_ci_span(c.buf, f.name, name) {
			continue
		}
		mut i := f.value.start
		end := f.value.start + f.value.len
		for i < end {
			for i < end && (c.buf[i] == ` ` || c.buf[i] == `\t` || c.buf[i] == `,`) {
				i++
			}
			s := i
			for i < end && c.buf[i] != `,` {
				i++
			}
			mut e := i
			for e > s && (c.buf[e - 1] == ` ` || c.buf[e - 1] == `\t`) {
				e--
			}
			if e - s == tok.len && eq_fold(str_view(c.buf, s, e - s), tok) {
				return true
			}
		}
	}
	return false
}

// valid_ws_key accepts the base64 of 16 bytes: 22 alphabet characters and '=='.
fn valid_ws_key(k string) bool {
	if k.len != 24 || k[22] != `=` || k[23] != `=` {
		return false
	}
	for i in 0 .. 22 {
		c := k[i]
		if !((c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`)
			|| (c >= `0` && c <= `9`) || c == `+` || c == `/`) {
			return false
		}
	}
	return true
}

// ws_accept writes Sec-WebSocket-Accept for a 24-byte key: base64(SHA-1(key + GUID)).
fn ws_accept(key string, mut out [28]u8) {
	mut msg := [60]u8{}
	unsafe {
		vmemcpy(&msg[0], key.str, 24)
		vmemcpy(&msg[24], ws_guid.str, 36)
	}
	mut d := [20]u8{}
	sha1(&msg[0], msg.len, mut d)
	mut o := 0
	for i := 0; i < 20; i += 3 {
		b0 := u32(d[i])
		b1 := if i + 1 < 20 { u32(d[i + 1]) } else { 0 }
		b2 := if i + 2 < 20 { u32(d[i + 2]) } else { 0 }
		v := b0 << 16 | b1 << 8 | b2
		out[o] = b64[v >> 18]
		out[o + 1] = b64[(v >> 12) & 63]
		out[o + 2] = if i + 1 < 20 { b64[(v >> 6) & 63] } else { `=` }
		out[o + 3] = if i + 2 < 20 { b64[v & 63] } else { `=` }
		o += 4
	}
}

// sha1 hashes p[0..n] for n < 120 (two blocks), enough for the handshake.
fn sha1(p &u8, n int, mut digest [20]u8) {
	mut b := [128]u8{}
	unsafe { vmemcpy(&b[0], p, n) }
	b[n] = 0x80
	nb := if n < 56 { 64 } else { 128 }
	bits := u64(n) * 8
	for i in 0 .. 8 {
		b[nb - 1 - i] = u8(bits >> (8 * i))
	}
	mut h := [u32(0x67452301), 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]!
	for off := 0; off < nb; off += 64 {
		sha1_block(mut h, &b[off])
	}
	for i in 0 .. 5 {
		digest[4 * i] = u8(h[i] >> 24)
		digest[4 * i + 1] = u8(h[i] >> 16)
		digest[4 * i + 2] = u8(h[i] >> 8)
		digest[4 * i + 3] = u8(h[i])
	}
}

fn sha1_block(mut h [5]u32, p &u8) {
	mut w := [80]u32{}
	for i in 0 .. 16 {
		unsafe {
			w[i] = u32(p[4 * i]) << 24 | u32(p[4 * i + 1]) << 16 | u32(p[4 * i + 2]) << 8 | u32(p[
				4 * i + 3])
		}
	}
	for i in 16 .. 80 {
		x := w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
		w[i] = x << 1 | x >> 31
	}
	mut a := h[0]
	mut b := h[1]
	mut c := h[2]
	mut d := h[3]
	mut e := h[4]
	for i in 0 .. 80 {
		mut f := u32(0)
		mut k := u32(0)
		if i < 20 {
			f = (b & c) | (~b & d)
			k = 0x5a827999
		} else if i < 40 {
			f = b ^ c ^ d
			k = 0x6ed9eba1
		} else if i < 60 {
			f = (b & c) | (b & d) | (c & d)
			k = 0x8f1bbcdc
		} else {
			f = b ^ c ^ d
			k = 0xca62c1d6
		}
		t := (a << 5 | a >> 27) + f + e + k + w[i]
		e = d
		d = c
		c = b << 30 | b >> 2
		b = a
		a = t
	}
	h[0] += a
	h[1] += b
	h[2] += c
	h[3] += d
	h[4] += e
}
