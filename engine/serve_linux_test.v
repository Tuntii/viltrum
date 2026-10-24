module engine

import net
import os
import time
import viltrum.http1
import viltrum.router

const big_body = 'b'.repeat(5 * 1024 * 1024)

fn h_path(mut c http1.Ctx) {
	c.text(200, c.path())
}

fn h_echo(mut c http1.Ctx) {
	c.bytes(200, 'text/plain', c.body())
}

fn h_big(mut c http1.Ctx) {
	c.text(200, big_body)
}

// A file past file_inline_max, so it is streamed with sendfile after the head.
const file_body = 'f'.repeat(3 * 1024 * 1024) + 'end'
const file_path = os.join_path(os.temp_dir(), 'viltrum-serve-${os.getpid()}.bin')

fn h_file(mut c http1.Ctx) {
	c.file(file_path)
}

fn h_delay_done(mut c http1.Ctx, ms u64) {
	c.text_int(200, i64(ms))
}

fn h_delay(mut c http1.Ctx) {
	ms := c.param_int('ms') or { 0 }
	c.after(int(ms), h_delay_done, u64(ms))
}

fn ws_echo(mut s http1.Ws, m http1.WsMessage) {
	if m.binary {
		s.send_binary(m.data)
	} else {
		s.send_text(m.text())
	}
}

const ws_h = &http1.WsHandler{
	on_message:   ws_echo
	idle_timeout: 300 * time.millisecond
}

fn h_ws(mut c http1.Ctx) {
	c.ws_upgrade(ws_h)
}

fn chat_msg(mut s http1.Ws, m http1.WsMessage) {
	t := m.text()
	if t.starts_with('sub:') {
		s.subscribe(t[4..])
		s.send_text('subscribed')
	} else if t.starts_with('pub:') {
		i := t.index_after(':', 4) or { return }
		s.publish(t[4..i], t[i + 1..])
	} else if t == 'id' {
		id := s.id()
		s.send_text('${id.worker} ${id.fd} ${id.gen}')
	}
}

const chat_h = &http1.WsHandler{
	on_message: chat_msg
}

fn h_chat(mut c http1.Ctx) {
	c.ws_upgrade(chat_h)
}

fn make_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/p/*rest', [http1.Handler(h_path)]) or { panic(err) }
	r.add(.get, '/ws', [http1.Handler(h_ws)]) or { panic(err) }
	r.add(.get, '/chat', [http1.Handler(h_chat)]) or { panic(err) }
	r.add(.post, '/echo', [http1.Handler(h_echo)]) or { panic(err) }
	r.add(.get, '/big', [http1.Handler(h_big)]) or { panic(err) }
	r.add(.get, '/file', [http1.Handler(h_file)]) or { panic(err) }
	r.add(.get, '/delay/:ms', [http1.Handler(h_delay)]) or { panic(err) }
	return r
}

fn free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	a := l.addr() or { panic(err) }
	s := a.str()
	l.close() or {}
	return s
}

fn start(opts Options) (string, &Stop) {
	addr := free_addr()
	mut stop := new_stop()
	o := Options{
		...opts
		workers:        2
		handle_signals: false
		stop:           stop
		send_date:      false
	}
	r := make_router()
	spawn fn [addr, r, o] () {
		serve(addr, r, o) or { eprintln(err) }
	}()
	for _ in 0 .. 100 {
		mut c := net.dial_tcp(addr) or {
			time.sleep(20 * time.millisecond)
			continue
		}
		c.close() or {}
		break
	}
	time.sleep(50 * time.millisecond)
	return addr, stop
}

fn dial(addr string) &net.TcpConn {
	mut c := net.dial_tcp(addr) or { panic(err) }
	c.set_read_timeout(5 * time.second)
	c.set_write_timeout(5 * time.second)
	return c
}

struct Reader {
mut:
	buf []u8
}

fn (mut r Reader) fill(mut conn net.TcpConn) ! {
	mut tmp := []u8{len: 64 * 1024}
	n := conn.read(mut tmp)!
	if n <= 0 {
		return error('eof')
	}
	r.buf << tmp[..n]
}

fn head_end(b []u8) int {
	for i := 0; i + 3 < b.len; i++ {
		if b[i] == `\r` && b[i + 1] == `\n` && b[i + 2] == `\r` && b[i + 3] == `\n` {
			return i + 4
		}
	}
	return -1
}

// response reads the next Content-Length framed response.
fn (mut r Reader) response(mut conn net.TcpConn) !(int, string) {
	for {
		end := head_end(r.buf)
		if end < 0 {
			r.fill(mut conn)!
			continue
		}
		cl := http1.header_value(r.buf[..end], 'content-length')
		n := if cl.found() { r.buf[cl.start..cl.start + cl.len].bytestr().int() } else { 0 }
		if r.buf.len < end + n {
			r.fill(mut conn)!
			continue
		}
		status := r.buf[9..12].bytestr().int()
		body := r.buf[end..end + n].bytestr()
		r.buf = r.buf[end + n..].clone()
		return status, body
	}
	return error('unreachable')
}

// closed is true when the connection ends before another complete response.
fn (mut r Reader) closed(mut conn net.TcpConn) bool {
	_, _ := r.response(mut conn) or { return true }
	return false
}

// read_until_eof returns the bytes read and whether the peer closed (eof) rather
// than the client read timeout firing.
fn read_until_eof(mut conn net.TcpConn) (int, bool) {
	mut tmp := []u8{len: 64 * 1024}
	mut total := 0
	for {
		n := conn.read(mut tmp) or { return total, err.code() != net.err_timed_out_code }
		if n <= 0 {
			return total, true
		}
		total += n
	}
	return total, true
}

fn test_pipelined_burst_with_bodies() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	mut burst := ''
	for i in 0 .. 300 {
		match i % 3 {
			0 {
				burst += 'GET /p/${i} HTTP/1.1\r\nHost: x\r\n\r\n'
			}
			1 {
				burst += 'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: ${i.str().len}\r\n\r\n${i}'
			}
			else {
				burst += 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n${i.str().len:x}\r\n${i}\r\n0\r\n\r\n'
			}
		}
	}
	c.write(burst.bytes()) or { panic(err) }
	mut r := Reader{}
	for i in 0 .. 300 {
		st, body := r.response(mut c) or { panic('${i}: ${err}') }
		assert st == 200
		want := if i % 3 == 0 { '/p/${i}' } else { '${i}' }
		assert body == want, '${i}'
	}
	c.close() or {}
}

fn test_bad_request_and_close_mid_burst() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	ok := 'GET /p/a HTTP/1.1\r\nHost: x\r\n\r\n'
	tails := {
		'GET /p/b HTTP/1.1\r\nHost : x\r\n\r\n':                     400
		'GET /p/b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n': 200
	}
	for tail, want in tails {
		mut c := dial(addr)
		c.write((ok + tail + ok).bytes()) or { panic(err) }
		mut r := Reader{}
		st1, _ := r.response(mut c) or { panic(err) }
		st2, _ := r.response(mut c) or { panic(err) }
		assert st1 == 200
		assert st2 == want
		assert r.closed(mut c), 'served after the connection should have closed'
		c.close() or {}
	}
}

fn test_trickled_requests() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	reqs :=
		'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n0\r\n\r\n' +
		'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello'
	for b in reqs.bytes() {
		c.write([b]) or { panic(err) }
		time.sleep(time.millisecond)
	}
	mut r := Reader{}
	_, b1 := r.response(mut c) or { panic(err) }
	_, b2 := r.response(mut c) or { panic(err) }
	assert b1 == 'Wiki' && b2 == 'hello'
	c.close() or {}
}

// Review Focus 2: a response far larger than the write buffer arrives complete and
// in order with the next pipelined response.
fn test_large_response_survives_partial_writes() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	c.write('GET /big HTTP/1.1\r\nHost: x\r\n\r\nGET /p/after HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or {
		panic(err)
	}
	mut r := Reader{}
	_, big := r.response(mut c) or { panic(err) }
	_, after := r.response(mut c) or { panic(err) }
	assert big.len == big_body.len && big == big_body
	assert after == '/p/after'
	c.close() or {}
}

// Review Focus 3: a client that pipelines and never reads is closed by write_timeout.
fn test_client_that_never_reads_is_closed() {
	addr, mut stop := start(Options{
		write_timeout: time.second
	})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	c.write('GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(30).bytes()) or { panic(err) }
	time.sleep(3500 * time.millisecond)
	got, _ := read_until_eof(mut c)
	assert got < 30 * big_body.len
	c.close() or {}
}

// Review Focus 4: trickling header bytes does not keep a connection alive past
// read_timeout.
fn test_slowloris_is_closed() {
	addr, mut stop := start(Options{
		read_timeout: time.second
	})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	c.write('GET /p/x HTTP/1.1\r\n'.bytes()) or { panic(err) }
	for _ in 0 .. 12 {
		time.sleep(200 * time.millisecond)
		c.write('X'.bytes()) or { break }
	}
	time.sleep(500 * time.millisecond)
	got, eof := read_until_eof(mut c)
	assert got == 0 && eof, 'server did not close the slow connection'
	c.close() or {}
}

fn test_idle_timeout_and_max_conns() {
	addr, mut stop := start(Options{
		idle_timeout: time.second
		max_conns:    1
	})
	defer {
		stop.request()
	}
	mut a := dial(addr)
	a.write('GET /p/a HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or { panic(err) }
	mut ra := Reader{}
	st, _ := ra.response(mut a) or { panic(err) }
	assert st == 200
	mut b := dial(addr)
	mut rb := Reader{}
	st503, _ := rb.response(mut b) or { panic(err) }
	assert st503 == 503
	b.close() or {}
	time.sleep(2500 * time.millisecond)
	got, eof := read_until_eof(mut a)
	assert got == 0 && eof, 'server did not close the idle connection'
	a.close() or {}
}

fn test_stop_closes_listeners() {
	addr, mut stop := start(Options{})
	stop.request()
	time.sleep(1500 * time.millisecond)
	mut c := net.dial_tcp(addr) or { return } // refused: what we want
	c.close() or {}
	assert false, 'still accepting after stop'
}

fn delay_for(i int) int {
	return 50 + (i * 13) % 150
}

// Many connections wait at once, each on its own delay: every one gets its own value
// no sooner than it asked, and the workers stay free to serve others meanwhile.
fn test_deferred_responses_concurrently() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	n := 300
	mut conns := []&net.TcpConn{}
	mut sent := []u64{}
	for i in 0 .. n {
		mut c := dial(addr)
		c.write_string('GET /delay/${delay_for(i)} HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
		conns << c
		sent << time.sys_mono_now()
	}
	mut q := dial(addr)
	t0 := time.sys_mono_now()
	q.write_string('GET /p/now HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	mut rq := Reader{}
	_, now_body := rq.response(mut q) or { panic(err) }
	assert now_body == '/p/now'
	assert time.sys_mono_now() - t0 < 40 * u64(time.millisecond), 'a worker was held by a waiting request'
	for i in 0 .. n {
		mut r := Reader{}
		status, body := r.response(mut conns[i]) or { panic(err) }
		assert status == 200 && body == delay_for(i).str()
		assert time.sys_mono_now() - sent[i] >= u64(delay_for(i)) * u64(time.millisecond)
	}
	for mut c in conns {
		c.close() or {}
	}
}

// A request pipelined behind a deferred one is answered after it, in order; a
// connection closed while waiting leaves a timer that must not answer anybody else.
fn test_deferred_pipeline_and_closed_waiter() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	for _ in 0 .. 20 {
		mut gone := dial(addr)
		gone.write_string('GET /delay/30 HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
		gone.close() or {}
	}
	mut c := dial(addr)
	c.write_string('GET /delay/60 HTTP/1.1\r\nHost: x\r\n\r\nGET /p/after HTTP/1.1\r\nHost: x\r\n\r\n') or {
		panic(err)
	}
	t0 := time.sys_mono_now()
	mut r := Reader{}
	_, first := r.response(mut c) or { panic(err) }
	assert first == '60' && time.sys_mono_now() - t0 >= 50 * u64(time.millisecond)
	_, second := r.response(mut c) or { panic(err) }
	assert second == '/p/after'
	c.close() or {}
}

fn C.socketpair(domain int, typ int, protocol int, sv &int) int

// fd numbers are process-wide, so with SO_REUSEPORT any worker sees any of them.
// A worker must pool its closed Conns, not keep one per fd number it ever saw:
// under connection churn that was a Conn per fd per worker (GBs at 64 workers).
fn test_closed_conns_are_pooled_per_worker() {
	mut stop := new_stop()
	mut count := &ConnCount{}
	mut l := &Loop{
		w:     new_worker(make_router(), Options{}, 0)
		epfd:  C.epoll_create1(0)
		lfds:  []int{}
		stop:  stop
		count: count
	}
	mut peers := []int{}
	mut first := unsafe { &Conn(nil) }
	mut last_fd := -1
	mut grew := 0
	for _ in 0 .. 100 {
		sv := [2]int{}
		assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
		// the kept end holds the fd number just freed, so connections get ever higher
		// numbers; servers of earlier tests still closing may free a lower one
		peers << sv[0]
		if sv[1] > last_fd {
			grew++
		}
		last_fd = sv[1]
		mut c := l.conn_for(sv[1])
		c.reset(sv[1])
		if isnil(first) {
			first = c
		}
		assert voidptr(c) == voidptr(first)
		l.close(mut c)
		assert isnil(l.conns[sv[1]])
	}
	assert l.free.len == 1 && grew >= 90
	for fd in peers {
		C.close(fd)
	}
	C.close(l.epfd)
}

const ws_upgrade_req = 'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'

// ws_cframe is a masked client frame.
fn ws_cframe(op u8, payload []u8) []u8 {
	mask := [u8(0xa1), 0x0b, 0x77, 0x3c]
	mut out := [u8(0x80 | op)]
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

// ws_open upgrades conn and leaves what followed the 101 in r.
fn ws_open(mut conn net.TcpConn, mut r Reader) ! {
	ws_open_path(mut conn, mut r, '/ws')!
}

fn ws_open_path(mut conn net.TcpConn, mut r Reader, path string) ! {
	conn.write(ws_upgrade_req.replace('/ws ', path + ' ').bytes())!
	for head_end(r.buf) < 0 {
		r.fill(mut conn)!
	}
	end := head_end(r.buf)
	assert r.buf[..end].bytestr().starts_with('HTTP/1.1 101 Switching Protocols\r\n')
	r.buf = r.buf[end..].clone()
}

// ws_read reads one server frame.
fn ws_read(mut conn net.TcpConn, mut r Reader) !(u8, []u8) {
	for {
		if r.buf.len >= 2 {
			mut n := u64(r.buf[1] & 0x7f)
			mut h := 2
			if n == 126 && r.buf.len >= 4 {
				n = u64(r.buf[2]) << 8 | u64(r.buf[3])
				h = 4
			} else if n == 127 && r.buf.len >= 10 {
				n = 0
				for k in 2 .. 10 {
					n = n << 8 | u64(r.buf[k])
				}
				h = 10
			}
			if (n < 126 || h > 2) && u64(r.buf.len) >= u64(h) + n {
				op := r.buf[0] & 0x0f
				data := r.buf[h..h + int(n)].clone()
				r.buf = r.buf[h + int(n)..].clone()
				return op, data
			}
		}
		r.fill(mut conn)!
	}
	return error('unreachable')
}

fn test_websocket_over_the_event_loop() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	mut r := Reader{}
	ws_open(mut c, mut r)!
	// a 600 KB message written in pieces grows the read buffer and comes back whole
	big := []u8{len: 600 * 1024, init: u8(index * 13)}
	f := ws_cframe(http1.ws_binary, big)
	for i := 0; i < f.len; i += 50000 {
		c.write(f[i..if i + 50000 < f.len { i + 50000 } else { f.len }])!
	}
	op, data := ws_read(mut c, mut r)!
	assert op == http1.ws_binary && data == big
	mut burst := []u8{}
	for i in 0 .. 100 {
		burst << ws_cframe(http1.ws_text, 'm${i}'.bytes())
	}
	c.write(burst)!
	for i in 0 .. 100 {
		op2, d2 := ws_read(mut c, mut r)!
		assert op2 == http1.ws_text && d2.bytestr() == 'm${i}'
	}
	// the Close is answered, then the server closes the connection
	c.write(ws_cframe(http1.ws_close, [u8(0x03), 0xe8]))!
	op3, d3 := ws_read(mut c, mut r)!
	assert op3 == http1.ws_close && d3 == [u8(0x03), 0xe8]
	_, eof := read_until_eof(mut c)
	assert eof
	c.close() or {}
	// a quiet connection is closed after the handler's idle timeout (swept each second)
	mut q := dial(addr)
	mut rq := Reader{}
	ws_open(mut q, mut rq)!
	t0 := time.ticks()
	_, eof2 := read_until_eof(mut q)
	assert eof2 && time.ticks() - t0 < 3000
	q.close() or {}
}

// Subscribers spread over both workers get what a client publishes (not the
// publisher), what another thread publishes, and a direct send by id.
fn test_websocket_publish_across_workers() {
	mut hub := new_hub()
	addr, mut stop := start(Options{
		hub: hub
	})
	defer {
		stop.request()
	}
	mut conns := []&net.TcpConn{}
	mut readers := []&Reader{}
	mut workers := map[string]bool{}
	for _ in 0 .. 8 {
		mut c := dial(addr)
		mut r := &Reader{}
		ws_open_path(mut c, mut r, '/chat')!
		c.write(ws_cframe(http1.ws_text, 'sub:room'.bytes()))!
		_, ok := ws_read(mut c, mut r)!
		assert ok.bytestr() == 'subscribed'
		c.write(ws_cframe(http1.ws_text, 'id'.bytes()))!
		_, id := ws_read(mut c, mut r)!
		workers[id.bytestr().all_before(' ')] = true
		conns << c
		readers << r
	}
	assert workers.len == 2, 'subscribers on both workers'
	conns[0].write(ws_cframe(http1.ws_text, 'pub:room:hi all'.bytes()))!
	for i in 1 .. 8 {
		_, got := ws_read(mut conns[i], mut readers[i])!
		assert got.bytestr() == 'hi all'
	}
	spawn fn [hub] () {
		hub.post(http1.ws_post('room', http1.WsId{}, http1.WsId{}, http1.ws_text, c'from a thread',
			13))
	}()
	for i in 0 .. 8 {
		_, got := ws_read(mut conns[i], mut readers[i])!
		assert got.bytestr() == 'from a thread', '${i}'
	}
	conns[5].write(ws_cframe(http1.ws_text, 'id'.bytes()))!
	_, raw := ws_read(mut conns[5], mut readers[5])!
	p := raw.bytestr().split(' ')
	hub.post(http1.ws_post('', http1.WsId{ worker: p[0].int(), fd: p[1].int(), gen: u32(p[2].int()) }, http1.WsId{},
		http1.ws_text, c'just you', 8))
	_, dm := ws_read(mut conns[5], mut readers[5])!
	assert dm.bytestr() == 'just you'
	for mut c in conns {
		c.close() or {}
	}
}

// A streamed file, read late so sendfile stops on a full socket, then a range of it
// and a plain request pipelined behind: all in order, all whole.
fn test_file_is_streamed_in_order() {
	os.write_file(file_path, file_body) or { panic(err) }
	defer {
		os.rm(file_path) or {}
	}
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	c.write(('GET /file HTTP/1.1\r\nHost: x\r\n\r\n' +
		'GET /file HTTP/1.1\r\nHost: x\r\nRange: bytes=-3\r\n\r\n' +
		'GET /p/after HTTP/1.1\r\nHost: x\r\n\r\n').bytes()) or { panic(err) }
	time.sleep(300 * time.millisecond)
	mut r := Reader{}
	st1, whole := r.response(mut c) or { panic(err) }
	assert st1 == 200 && whole.len == file_body.len && whole == file_body
	st2, tail := r.response(mut c) or { panic(err) }
	assert st2 == 206 && tail == 'end'
	st3, after := r.response(mut c) or { panic(err) }
	assert st3 == 200 && after == '/p/after'
	c.close() or {}
}

fn open_fds() int {
	return (os.ls('/proc/self/fd') or { [] }).len
}

// Clients that leave mid-file: the open file is closed with the connection.
fn test_file_closed_with_the_connection() {
	os.write_file(file_path, file_body) or { panic(err) }
	defer {
		os.rm(file_path) or {}
	}
	addr, mut stop := start(Options{
		write_timeout: time.second
	})
	defer {
		stop.request()
	}
	before := open_fds()
	for _ in 0 .. 8 {
		mut c := dial(addr)
		c.write('GET /file HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()) or { panic(err) }
		time.sleep(20 * time.millisecond)
		c.close() or {}
	}
	// a client that stays but never reads is cut by write_timeout, more than socket
	// buffers hold still unsent
	mut idle := dial(addr)
	idle.write('GET /file HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(20).bytes()) or { panic(err) }
	time.sleep(3500 * time.millisecond)
	got, _ := read_until_eof(mut idle)
	assert got < 20 * file_body.len
	idle.close() or {}
	time.sleep(200 * time.millisecond)
	assert open_fds() <= before
}

// A client that writes its whole upload before reading: the 413 comes before the
// body, and the connection is drained rather than reset, so the upload completes and
// the 413 is still there to read.
fn test_refused_upload_is_drained_not_reset() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	body := 'u'.repeat(4 * 1024 * 1024)
	mut c := dial(addr)
	c.write('POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: ${body.len}\r\n\r\n'.bytes()) or {
		panic(err)
	}
	time.sleep(50 * time.millisecond) // the 413 is out and the server is closing
	c.write(body.bytes()) or { assert false, 'upload reset: ${err}' }
	mut r := Reader{}
	st, _ := r.response(mut c) or { panic(err) }
	assert st == 413
	assert r.closed(mut c)
	c.close() or {}
}

// A chunked body of one-byte chunks reaches the read cap on its size lines before the
// body limit: 413, not a silent close.
fn test_chunk_overhead_at_the_read_cap_is_413() {
	addr, mut stop := start(Options{
		limits: http1.Limits{
			max_body_bytes: 64 * 1024
		}
	})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	head := 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n'
	c.write((head + '1\r\nx\r\n'.repeat(60000)).bytes()) or { assert false, 'reset: ${err}' }
	mut r := Reader{}
	st, body := r.response(mut c) or { panic(err) }
	assert st == 413 && body == 'payload too large'
	assert r.closed(mut c)
	c.close() or {}
}

// A lingering client that neither sends nor closes is closed after linger_idle_ms.
fn test_lingering_client_is_closed() {
	addr, mut stop := start(Options{})
	defer {
		stop.request()
	}
	mut c := dial(addr)
	c.write('GET /p/x HTTP/1.1\r\nHost : x\r\n\r\n'.bytes()) or { panic(err) }
	mut r := Reader{}
	st, _ := r.response(mut c) or { panic(err) }
	assert st == 400
	assert r.closed(mut c) // the server's FIN follows the response
	// lingering, what the client sends is dropped without a reset
	c.write('more'.bytes()) or { panic(err) }
	time.sleep(100 * time.millisecond)
	c.write('more'.bytes()) or { assert false, 'reset while lingering: ${err}' }
	// once the server has closed, the next write is answered with RST
	time.sleep((linger_idle_ms + 1500) * time.millisecond)
	c.write('late'.bytes()) or {}
	time.sleep(100 * time.millisecond)
	mut reset := false
	c.write('late'.bytes()) or { reset = true }
	assert reset, 'still lingering after linger_idle_ms'
	c.close() or {}
}

// The loop sleeps until the next deferred response, not until the next whole
// millisecond: epoll_wait's rounding made /delay answers up to 1 ms late.
fn test_wait_ns_keeps_sub_millisecond_timeouts() {
	mut stop := new_stop()
	mut count := &ConnCount{}
	mut l := &Loop{
		w:     new_worker(make_router(), Options{}, 0)
		stop:  stop
		count: count
	}
	assert l.wait_ns() == max_wait_ns
	l.w.timers.push(time.sys_mono_now() + 300_000, 0, 0)
	ns := l.wait_ns()
	assert ns > 0 && ns <= 300_000
	l.w.timers.push(time.sys_mono_now() + 10 * u64(time.second), 1, 0)
	assert l.wait_ns() <= 300_000 // the earliest one counts
	l.w.timers.push(0, 2, 0)
	assert l.wait_ns() == 0
}

// Port 0 asks the kernel for a port once: the other workers join that port instead
// of each getting a port of its own.
fn test_port_zero_is_one_port_for_every_worker() {
	mut lns := [Listener{
		addr: '127.0.0.1:0'
	}, Listener{
		addr: free_addr()
	}]
	fixed := lns[1].addr
	lfds := open_listeners(mut lns, 3) or { panic(err) }
	assert lns[0].addr != '127.0.0.1:0' && lns[0].addr.starts_with('127.0.0.1:')
	assert lns[1].addr == fixed
	port := net.addr_from_socket_handle(lfds[0][0]).port() or { panic(err) }
	assert lns[0].addr == '127.0.0.1:${port}'
	for row in lfds {
		assert row.len == 2
		assert (net.addr_from_socket_handle(row[0]).port() or { panic(err) }) == port
	}
	for row in lfds {
		for fd in row {
			C.close(fd)
		}
	}
}

// A listener that cannot bind fails the start and leaves no socket open, its own
// included.
fn test_failed_listen_leaves_nothing_open() {
	// held without SO_REUSEPORT, so no worker can join it
	mut taken := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	busy := (taken.addr() or { panic(err) }).str()
	before := open_fds()
	mut lns := [Listener{
		addr: '127.0.0.1:0'
	}, Listener{
		addr: busy
	}]
	if _ := open_listeners(mut lns, 2) {
		assert false, 'bound a port that is taken'
	}
	assert open_fds() == before
	taken.close() or {}
}
