module engine

import viltrum.http1
import viltrum.router

@[heap]
struct Seen {
mut:
	opened int
	closed []int
	room   string
}

fn echo_msg(mut s http1.Ws, m http1.WsMessage) {
	if m.binary {
		s.send_binary(m.data)
	} else if m.text() == 'bye' {
		s.close(4000, 'done')
	} else {
		s.send_text(m.text())
	}
}

// full_handler records its callbacks in seen.
fn full_handler(mut seen Seen) &http1.WsHandler {
	return &http1.WsHandler{
		on_open:    fn [mut seen] (mut s http1.Ws, mut c http1.Ctx) {
			seen.opened++
			seen.room = (c.param('room') or { '' }).clone()
			s.send_text('hi ${seen.room}')
		}
		on_message: echo_msg
		on_close:   fn [mut seen] (mut s http1.Ws, code int) {
			seen.closed << code
			s.send_text('dropped')
		}
		protocols:  ['v2.chat', 'chat']
	}
}

// chat_msg understands 'sub:T', 'unsub:T', 'pub:T:text' and 'id'; it echoes the rest.
fn chat_msg(mut s http1.Ws, m http1.WsMessage) {
	t := m.text()
	if t.starts_with('sub:') {
		s.subscribe(t[4..])
		s.send_text('subscribed')
	} else if t.starts_with('unsub:') {
		s.unsubscribe(t[6..])
	} else if t.starts_with('pub:') {
		i := t.index_after(':', 4) or { return }
		s.publish(t[4..i], t[i + 1..])
	} else if t == 'id' {
		id := s.id()
		s.send_text('${id.worker} ${id.fd} ${id.gen}')
	} else {
		s.send_text(t)
	}
}

fn up(h &http1.WsHandler) http1.Handler {
	return fn [h] (mut c http1.Ctx) {
		c.ws_upgrade(h)
	}
}

fn ws_router(mut seen Seen) &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/ws', [up(&http1.WsHandler{ on_message: echo_msg })]) or { panic(err) }
	r.add(.get, '/room/:room', [up(full_handler(mut seen))]) or { panic(err) }
	r.add(.get, '/chat', [up(&http1.WsHandler{ on_message: chat_msg })]) or { panic(err) }
	r.add(.get, '/small', [
		up(&http1.WsHandler{ on_message: echo_msg, max_message: 100 }),
	]) or { panic(err) }
	return r
}

fn new_ws_worker(opts Options) &Worker {
	mut seen := &Seen{}
	return new_worker(ws_router(mut seen), opts, 0)
}

const key = 'dGhlIHNhbXBsZSBub25jZQ=='

fn upgrade_req(path string, extra string) string {
	return 'GET ${path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n${extra}\r\n'
}

// cframe is a client frame: masked, as RFC 6455 requires.
fn cframe(op u8, fin bool, payload []u8) []u8 {
	mask := [u8(0x37), 0xfa, 0x21, 0x3d]
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

fn ctext(s string) []u8 {
	return cframe(http1.ws_text, true, s.bytes())
}

fn cclose(code int) []u8 {
	return cframe(http1.ws_close, true, [u8(code >> 8), u8(code)])
}

struct SFrame {
	op   u8
	fin  bool
	data []u8
}

// sframes splits server output after the 101 head into frames, checking each is unmasked.
fn sframes(b []u8) []SFrame {
	mut i := 0
	mut out := []SFrame{}
	for i < b.len {
		assert b[i + 1] & 0x80 == 0, 'server frames are not masked'
		mut n := u64(b[i + 1] & 0x7f)
		mut h := 2
		if n == 126 {
			n = u64(b[i + 2]) << 8 | u64(b[i + 3])
			h = 4
		} else if n == 127 {
			n = 0
			for k in 2 .. 10 {
				n = n << 8 | u64(b[i + k])
			}
			h = 10
		}
		out << SFrame{
			op:   b[i] & 0x0f
			fin:  b[i] & 0x80 != 0
			data: b[i + h..i + h + int(n)].clone()
		}
		i += h + int(n)
	}
	return out
}

fn after_head(b []u8) []u8 {
	s := b.bytestr()
	i := s.index('\r\n\r\n') or { return b }
	return b[i + 4..].clone()
}

fn feed(mut w Worker, mut c Conn, b []u8) {
	unsafe { c.rbuf.push_many(b.data, b.len) }
	w.process(mut c)
	for !c.close_after && c.rbuf.len > 0 {
		before := c.rbuf.len
		w.process(mut c)
		if c.rbuf.len == before {
			break
		}
	}
}

fn fresh(path string, extra string) (&Worker, &Conn, string) {
	mut w := new_ws_worker(Options{ send_date: false })
	mut c := new_conn()
	c.fd = 3
	feed(mut w, mut c, upgrade_req(path, extra).bytes())
	head := c.wbuf.bytestr()
	unsafe {
		c.wbuf.len = 0
	}
	return w, c, head
}

fn test_handshake() {
	_, c, head := fresh('/ws', '')
	assert head.starts_with('HTTP/1.1 101 Switching Protocols\r\n')
	assert head.contains('Upgrade: websocket\r\n') && head.contains('Connection: Upgrade\r\n')
	assert head.contains('Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n')
	assert !head.contains('Content-Length') && !head.contains('Sec-WebSocket-Protocol')
	assert !isnil(c.ws) && !c.close_after && !c.reading
}

fn test_echo_text_binary_and_burst() {
	mut w, mut c, _ := fresh('/ws', '')
	bin := []u8{len: 256, init: u8(index * 7)}
	mut b := ctext('hello')
	b << cframe(http1.ws_binary, true, bin)
	for i in 0 .. 5 {
		b << ctext('msg-${i}')
	}
	feed(mut w, mut c, b)
	f := sframes(c.wbuf)
	assert f.len == 7
	assert f[0].op == http1.ws_text && f[0].fin && f[0].data.bytestr() == 'hello'
	assert f[1].op == http1.ws_binary && f[1].data == bin
	for i in 0 .. 5 {
		assert f[2 + i].data.bytestr() == 'msg-${i}'
	}
	assert c.rbuf.len == 0
}

fn test_frames_behind_the_upgrade_in_one_read() {
	mut w := new_ws_worker(Options{ send_date: false })
	mut c := new_conn()
	mut b := upgrade_req('/ws', '').bytes()
	b << ctext('early')
	feed(mut w, mut c, b)
	f := sframes(after_head(c.wbuf))
	assert f.len == 1 && f[0].data.bytestr() == 'early'
}

fn test_frames_split_across_reads() {
	mut w, mut c, _ := fresh('/ws', '')
	msg := 'x'.repeat(300) // 16-bit length
	b := ctext(msg)
	for i in 0 .. b.len {
		feed(mut w, mut c, [b[i]])
		if i < b.len - 1 {
			assert c.wbuf.len == 0
		}
	}
	f := sframes(c.wbuf)
	assert f.len == 1 && f[0].data.bytestr() == msg
}

fn test_large_message_uses_64_bit_length() {
	mut w, mut c, _ := fresh('/ws', '')
	bin := []u8{len: 70000, init: u8(index)}
	feed(mut w, mut c, cframe(http1.ws_binary, true, bin))
	f := sframes(c.wbuf)
	assert f.len == 1 && f[0].data == bin
	assert c.wbuf[1] == 127
}

fn test_fragments_with_ping_between() {
	mut w, mut c, _ := fresh('/ws', '')
	mut b := cframe(http1.ws_text, false, 'frag'.bytes())
	b << cframe(0, false, 'men'.bytes())
	b << cframe(http1.ws_ping, true, 'p!'.bytes())
	b << cframe(0, true, 'ted'.bytes())
	feed(mut w, mut c, b)
	f := sframes(c.wbuf)
	assert f.len == 2
	assert f[0].op == http1.ws_pong && f[0].data.bytestr() == 'p!'
	assert f[1].op == http1.ws_text && f[1].data.bytestr() == 'fragmented'
	assert c.ws_frag == 0 && c.ws_msg.len == 0
}

fn test_pong_is_absorbed() {
	mut w, mut c, _ := fresh('/ws', '')
	feed(mut w, mut c, cframe(http1.ws_pong, true, []u8{}))
	assert c.wbuf.len == 0 && !c.close_after
}

fn test_client_close_is_answered() {
	mut w, mut c, _ := fresh('/ws', '')
	mut b := cclose(1000)
	b << ctext('after close')
	feed(mut w, mut c, b)
	f := sframes(c.wbuf)
	assert f.len == 1 && f[0].op == http1.ws_close && f[0].data == [u8(0x03), 0xe8]
	assert c.close_after && c.ws_code == 1000 && c.rbuf.len == 0
	// a Close without a code is answered without one
	mut w2, mut c2, _ := fresh('/ws', '')
	feed(mut w2, mut c2, cframe(http1.ws_close, true, []u8{}))
	f2 := sframes(c2.wbuf)
	assert f2.len == 1 && f2[0].data.len == 0 && c2.ws_code == 1005
}

fn fails_with(b []u8, code int) {
	mut w, mut c, _ := fresh('/small', '')
	feed(mut w, mut c, b)
	f := sframes(c.wbuf)
	assert f.len == 1 && f[0].op == http1.ws_close, b.hex()
	got := int(u16(f[0].data[0]) << 8 | u16(f[0].data[1]))
	assert got == code && c.close_after && c.ws_code == code, b.hex()
}

fn test_protocol_errors_close_the_connection() {
	mut unmasked := ctext('hi')
	unmasked[1] &= 0x7f
	fails_with(unmasked, 1002)
	mut rsv := ctext('hi')
	rsv[0] |= 0x40
	fails_with(rsv, 1002)
	fails_with(cframe(3, true, []u8{}), 1002)
	fails_with(cframe(0xb, true, []u8{}), 1002)
	fails_with(cframe(http1.ws_ping, false, []u8{}), 1002)
	fails_with(cframe(http1.ws_ping, true, []u8{len: 126}), 1002)
	fails_with(cframe(0, true, 'x'.bytes()), 1002)
	mut two_starts := cframe(http1.ws_text, false, 'a'.bytes())
	two_starts << ctext('b')
	fails_with(two_starts, 1002)
	fails_with(cframe(http1.ws_close, true, [u8(3)]), 1002)
	fails_with(cclose(1005), 1002)
	fails_with(cclose(999), 1002)
	fails_with(cframe(http1.ws_text, true, [u8(0xc3), 0x28]), 1007)
	mut bad_reason := [u8(0x03), 0xe8]
	bad_reason << [u8(0xff)]
	fails_with(cframe(http1.ws_close, true, bad_reason), 1007)
	fails_with(ctext('y'.repeat(101)), 1009)
	mut grown := cframe(http1.ws_binary, false, []u8{len: 60})
	grown << cframe(0, true, []u8{len: 41})
	fails_with(grown, 1009)
	// the size check comes from the header alone, before the payload arrives
	mut w, mut c, _ := fresh('/small', '')
	feed(mut w, mut c, cframe(http1.ws_binary, true, []u8{len: 1 << 20})[..14])
	assert c.close_after && c.ws_code == 1009
}

fn test_server_close_waits_for_the_client() {
	mut w, mut c, _ := fresh('/ws', '')
	mut b := ctext('bye')
	b << ctext('ignored')
	feed(mut w, mut c, b)
	f := sframes(c.wbuf)
	assert f.len == 1 && f[0].op == http1.ws_close && f[0].data.bytestr()[2..] == 'done'
	assert c.ws_closing && !c.close_after
	unsafe {
		c.wbuf.len = 0
	}
	feed(mut w, mut c, cclose(4000))
	assert c.wbuf.len == 0 && c.close_after && c.ws_code == 4000
}

fn test_open_close_params_and_subprotocol() {
	mut seen := &Seen{}
	mut w := new_worker(ws_router(mut seen), Options{ send_date: false }, 0)
	mut c := new_conn()
	feed(mut w, mut c,
		upgrade_req('/room/blue', 'Sec-WebSocket-Protocol: chat, v2.chat\r\n').bytes())
	assert c.wbuf.bytestr().contains('Sec-WebSocket-Protocol: v2.chat\r\n')
	assert seen.opened == 1 && seen.room == 'blue'
	// on_open's message follows the 101 in the same output
	f := sframes(after_head(c.wbuf))
	assert f.len == 1 && f[0].data.bytestr() == 'hi blue'
	assert w.ws.protocol() == 'v2.chat'
	unsafe {
		c.wbuf.len = 0
	}
	feed(mut w, mut c, cclose(1001))
	unsafe {
		c.wbuf.len = 0
	}
	w.ws_end(mut c)
	w.ws_end(mut c)
	assert seen.closed == [1001] && c.wbuf.len == 0 && isnil(c.ws)
	mut c2 := new_conn()
	feed(mut w, mut c2, upgrade_req('/room/red', '').bytes())
	assert !c2.wbuf.bytestr().contains('Sec-WebSocket-Protocol')
	assert seen.opened == 2 && seen.room == 'red'
	// a connection that ends without a Close reports 1006
	w.ws_end(mut c2)
	assert seen.closed == [1001, 1006]
}

fn test_bad_upgrades_are_refused() {
	mut w := new_ws_worker(Options{ send_date: false })
	mut c := new_conn()
	cases := {
		'GET /ws HTTP/1.1\r\nHost: x\r\n\r\n':                                                                                                               '426'
		upgrade_req('/ws', '').replace('Version: 13', 'Version: 8'):                                                                                         '426'
		upgrade_req('/ws', '').replace(key, 'short'):                                                                                                        '400'
		upgrade_req('/ws', '').replace('keep-alive, Upgrade', 'keep-alive'):                                                                                 '400'
		upgrade_req('/ws', 'Content-Length: 2\r\n') + 'ab':                                                                                                  '400'
		upgrade_req('/ws', '').replace('HTTP/1.1', 'HTTP/1.0'):                                                                                              '400'
		'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade, close\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n': '400'
	}
	for raw, code in cases {
		unsafe {
			c.rbuf.len = 0
			c.wbuf.len = 0
		}
		c.reset(3)
		feed(mut w, mut c, raw.bytes())
		s := c.wbuf.bytestr()
		assert s.starts_with('HTTP/1.1 ${code} '), raw
		assert isnil(c.ws), raw
	}
	unsafe {
		c.wbuf.len = 0
	}
	c.reset(3)
	feed(mut w, mut c, upgrade_req('/ws', '').replace('Version: 13', 'Version: 8').bytes())
	assert c.wbuf.bytestr().contains('Sec-WebSocket-Version: 13\r\n')
}

fn test_backpressure_pauses_reading_frames() {
	mut w := new_ws_worker(Options{
		send_date:   false
		max_pending: 100
	})
	mut c := new_conn()
	feed(mut w, mut c, upgrade_req('/ws', '').bytes())
	unsafe {
		c.wbuf.len = 0
	}
	mut b := []u8{}
	for _ in 0 .. 20 {
		b << ctext('0123456789')
	}
	unsafe { c.rbuf.push_many(b.data, b.len) }
	w.process(mut c)
	first := sframes(c.wbuf).len
	assert first > 0 && first < 20
	mut total := first
	for total < 20 {
		unsafe {
			c.wbuf.len = 0
		}
		w.process(mut c)
		total += sframes(c.wbuf).len
	}
	assert total == 20 && c.rbuf.len == 0
}

fn test_echo_allocates_nothing() {
	mut w, mut c, _ := fresh('/ws', '')
	mut b := ctext('hello there')
	b << cframe(http1.ws_binary, true, []u8{len: 300})
	b << cframe(http1.ws_ping, true, 'p'.bytes())
	run_ws := fn [b] (mut w Worker, mut c Conn) {
		unsafe {
			c.wbuf.len = 0
			c.rbuf.push_many(b.data, b.len)
		}
		w.process(mut c)
	}
	for _ in 0 .. 200 {
		run_ws(mut w, mut c)
	}
	before := http1.allocated_bytes()
	for _ in 0 .. 10000 {
		run_ws(mut w, mut c)
	}
	assert http1.allocated_bytes() - before == 0
	assert sframes(c.wbuf).len == 3
}

fn topic_size(w &Worker, name string) int {
	t := w.topics[name] or { return 0 }
	return t.conns.len
}

// joined upgrades a connection on fd to /chat and clears its output.
fn joined(mut w Worker, fd int, mut conns []&Conn) &Conn {
	mut c := new_conn()
	c.reset(fd)
	w.gen++
	c.gen = w.gen
	conns[fd] = c
	feed(mut w, mut c, upgrade_req('/chat', '').bytes())
	unsafe {
		c.wbuf.len = 0
	}
	return c
}

fn texts(c &Conn) []string {
	return sframes(c.wbuf).map(it.data.bytestr())
}

fn clear_out(cs []&Conn) {
	for c in cs {
		unsafe {
			c.wbuf.len = 0
		}
	}
}

// deliver_all is the event loop's inbox drain without the sockets.
fn deliver_all(mut w Worker, mut h Hub, mut conns []&Conn) []&Conn {
	mut posts := []&http1.WsPost{}
	h.boxes[0].take(mut posts)
	mut touched := []&Conn{}
	for p in posts {
		w.deliver(p, mut conns, mut touched)
	}
	for mut c in touched {
		c.touched = false
	}
	return touched
}

fn test_publish_subscribe_and_direct_send() {
	mut h := new_hub()
	h.open(1)!
	defer {
		h.close()
	}
	mut w := new_ws_worker(Options{ send_date: false })
	w.hub = h
	mut conns := unsafe { []&Conn{len: 16} }
	mut a := joined(mut w, 3, mut conns)
	mut b := joined(mut w, 4, mut conns)
	mut c := joined(mut w, 5, mut conns)
	feed(mut w, mut a, ctext('sub:room'))
	feed(mut w, mut b, ctext('sub:room'))
	feed(mut w, mut b, ctext('sub:room')) // twice is once
	assert topic_size(w, 'room') == 2 && b.subs.len == 1
	clear_out([a, b, c])
	feed(mut w, mut a, ctext('pub:room:hello'))
	assert a.wbuf.len == 0 // nothing until the inbox is drained
	touched := deliver_all(mut w, mut h, mut conns)
	assert texts(b) == ['hello'] && texts(a).len == 0 && texts(c).len == 0
	assert touched.len == 1 && voidptr(touched[0]) == voidptr(b)
	// from outside a callback every subscriber gets it, the publisher too
	clear_out([a, b, c])
	h.post(http1.ws_post('room', http1.WsId{}, http1.WsId{}, http1.ws_binary, c'x', 1))
	h.post(http1.ws_post('nobody', http1.WsId{}, http1.WsId{}, http1.ws_text, c'y', 1))
	deliver_all(mut w, mut h, mut conns)
	assert sframes(a.wbuf)[0].op == http1.ws_binary && texts(a) == ['x'] && texts(b) == ['x']
	assert texts(c).len == 0
	// direct send by id; a stale id (the connection was replaced) is dropped
	clear_out([a, b, c])
	feed(mut w, mut c, ctext('id'))
	parts := texts(c)[0].split(' ')
	id := http1.WsId{
		worker: parts[0].int()
		fd:     parts[1].int()
		gen:    u32(parts[2].int())
	}
	assert id.fd == 5 && id.gen == c.gen
	clear_out([c])
	h.post(http1.ws_post('', id, http1.WsId{}, http1.ws_text, c'dm', 2))
	h.post(http1.ws_post('', http1.WsId{ fd: 5, gen: c.gen + 100 }, http1.WsId{}, http1.ws_text,
		c'stale', 5))
	deliver_all(mut w, mut h, mut conns)
	assert texts(c) == ['dm']
	// unsubscribe and close leave the topic, the last one out removes it
	feed(mut w, mut b, ctext('unsub:room'))
	assert topic_size(w, 'room') == 1 && b.subs.len == 0
	w.ws_end(mut a)
	assert 'room' !in w.topics && a.subs.len == 0
}

fn test_publish_to_a_slow_client_closes_it() {
	mut h := new_hub()
	h.open(1)!
	defer {
		h.close()
	}
	mut w := new_ws_worker(Options{
		send_date:   false
		max_pending: 100
	})
	w.hub = h
	mut conns := unsafe { []&Conn{len: 16} }
	mut a := joined(mut w, 3, mut conns)
	feed(mut w, mut a, ctext('sub:t'))
	for _ in 0 .. 50 {
		h.post(http1.ws_post('t', http1.WsId{}, http1.WsId{}, http1.ws_text, c'0123456789', 10))
	}
	deliver_all(mut w, mut h, mut conns)
	f := sframes(a.wbuf)
	assert f.last().op == http1.ws_close && a.close_after && a.ws_code == 1008
	assert f.len < 50
}
