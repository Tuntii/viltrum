module engine

import net
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

fn h_delay_done(mut c http1.Ctx, ms u64) {
	c.text_int(200, i64(ms))
}

fn h_delay(mut c http1.Ctx) {
	ms := c.param_int('ms') or { 0 }
	c.after(int(ms), h_delay_done, u64(ms))
}

fn make_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/p/*rest', [http1.Handler(h_path)]) or { panic(err) }
	r.add(.post, '/echo', [http1.Handler(h_echo)]) or { panic(err) }
	r.add(.get, '/big', [http1.Handler(h_big)]) or { panic(err) }
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
	for _ in 0 .. 100 {
		sv := [2]int{}
		assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
		// the kept end holds the fd number just freed, so every connection gets a new one
		peers << sv[0]
		assert sv[1] > last_fd
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
	assert l.free.len == 1
	for fd in peers {
		C.close(fd)
	}
	C.close(l.epfd)
}
