module engine

import net
import os
import time
import viltrum.http1
import viltrum.router

// Ctx.fetch over real sockets: a front server whose handlers fetch from an upstream,
// which is either another viltrum server (start) or a scripted one (raw_upstream).

const up0 = http1.Upstream{
	id: 0
}

// f_answer writes what the fetch got: the upstream's status and body, or 599 and
// the error's name.
fn f_answer(mut c http1.Ctx, arg u64) {
	r := c.fetched()
	if r.err != .none {
		c.text(599, '${r.err}')
		return
	}
	c.bytes(r.status, c.fetched_header('content-type') or { 'x/none' }, r.body)
}

fn f_get(mut c http1.Ctx) {
	c.fetch(up0, .get, '/' + c.param('rest') or { '' }, f_answer, 0)
}

// f_px fetches a fixed target, so the handler itself allocates nothing.
fn f_px(mut c http1.Ctx) {
	c.fetch(up0, .get, '/p/x', f_answer, 0)
}

fn f_post(mut c http1.Ctx) {
	c.fetch(up0, .post, '/echo', f_answer, 0)
	c.fetch_body(c.body())
	c.fetch_header('Content-Type', 'text/x-test')
}

// f_chain fetches twice in a row: the second fetch from the first one's callback.
fn f_chain(mut c http1.Ctx) {
	c.fetch(up0, .get, '/p/one', f_chain_2, 0)
}

fn f_chain_2(mut c http1.Ctx, arg u64) {
	r := c.fetched()
	if r.err != .none {
		c.text(599, '${r.err}')
		return
	}
	c.fetch(up0, .get, '/p/two?after=' + r.body.bytestr().all_after_last('/'), f_answer, 0)
}

// --- the upstream: a viltrum server ---

fn u_path(mut c http1.Ctx) {
	c.text(200, c.path())
}

fn u_echo(mut c http1.Ctx) {
	c.bytes(200, c.header('content-type') or { 'x/none' }, c.body())
}

fn u_big(mut c http1.Ctx) {
	c.text(200, 'b'.repeat(100 * 1024))
}

fn u_delay_done(mut c http1.Ctx, ms u64) {
	c.text_int(200, i64(ms))
}

fn u_delay(mut c http1.Ctx) {
	ms := c.param_int('ms') or { 0 }
	c.after(int(ms), u_delay_done, u64(ms))
}

fn up_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/p/*rest', [http1.Handler(u_path)]) or { panic(err) }
	r.add(.post, '/echo', [http1.Handler(u_echo)]) or { panic(err) }
	r.add(.get, '/big', [http1.Handler(u_big)]) or { panic(err) }
	r.add(.get, '/delay/:ms', [http1.Handler(u_delay)]) or { panic(err) }
	return r
}

fn start(opts Options) (string, &Stop) {
	return serve_on(up_router(), opts, false)
}

// --- the front: handlers that fetch ---

fn front_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/f/*rest', [http1.Handler(f_get)]) or { panic(err) }
	r.add(.post, '/f-post', [http1.Handler(f_post)]) or { panic(err) }
	r.add(.get, '/fx', [http1.Handler(f_px)]) or { panic(err) }
	r.add(.get, '/f-chain', [http1.Handler(f_chain)]) or { panic(err) }
	return r
}

// start_front serves front_router with one upstream at up_addr.
fn start_front(up_addr string, uo UpstreamOptions, h2 bool) (string, &Stop) {
	spec := new_upstream('http://${up_addr}', uo) or { panic(err) }
	return serve_on(front_router(), Options{
		upstreams: [spec]
	}, h2)
}

fn serve_on(r &router.Router, opts Options, h2 bool) (string, &Stop) {
	addr := free_addr()
	mut stop := new_stop()
	o := Options{
		...opts
		workers:        2
		handle_signals: false
		stop:           stop
		send_date:      false
	}
	ls := [Listener{
		addr:  addr
		http2: h2
	}]
	spawn fn [ls, r, o] () {
		serve_listeners(ls, r, o) or { eprintln(err) }
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

fn free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	a := l.addr() or { panic(err) }
	s := a.str()
	l.close() or {}
	return s
}

fn dial(addr string) &net.TcpConn {
	mut c := net.dial_tcp(addr) or { panic(err) }
	c.set_read_timeout(5 * time.second)
	c.set_write_timeout(5 * time.second)
	return c
}

fn sh(cmd string) os.Result {
	return os.exec(['/bin/sh', '-c', cmd])
}

fn head_end(b []u8) int {
	for i := 0; i + 3 < b.len; i++ {
		if b[i] == `\r` && b[i + 1] == `\n` && b[i + 2] == `\r` && b[i + 3] == `\n` {
			return i + 4
		}
	}
	return -1
}

struct Reader {
mut:
	buf []u8
}

// response reads the next Content-Length framed response.
fn (mut r Reader) response(mut conn net.TcpConn) !(int, string) {
	mut tmp := []u8{len: 64 * 1024}
	for {
		end := head_end(r.buf)
		if end >= 0 {
			cl := http1.header_value(r.buf[..end], 'content-length')
			n := if cl.found() { r.buf[cl.start..cl.start + cl.len].bytestr().int() } else { 0 }
			if r.buf.len >= end + n {
				status := r.buf[9..12].bytestr().int()
				body := r.buf[end..end + n].bytestr()
				r.buf = r.buf[end + n..].clone()
				return status, body
			}
		}
		k := conn.read(mut tmp)!
		if k <= 0 {
			return error('eof')
		}
		r.buf << tmp[..k]
	}
	return error('unreachable')
}

fn get(mut c net.TcpConn, mut r Reader, path string) (int, string) {
	c.write_string('GET ${path} HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	return r.response(mut c) or { panic(err) }
}

// roundtrip sends req on fd and reads one response of want bytes into buf, with the
// socket calls alone, so the test itself allocates nothing.
fn roundtrip(fd int, req string, mut buf []u8, want int) {
	C.send(fd, req.str, req.len, 0)
	mut got := 0
	for got < want {
		n := int(C.recv(fd, unsafe { &u8(buf.data) + got }, buf.len - got, 0))
		assert n > 0
		got += n
	}
	assert got == want
}

// The zero-allocation gate for fetch: once the pool is warm, a request that fetches
// from an upstream allocates nothing, front and upstream together. First in the file,
// so no earlier test's server is still shutting down.
fn test_fetch_allocates_nothing() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{}, false)
	defer {
		stop.request()
	}
	mut c := dial(front)
	mut r := Reader{}
	st, _ := get(mut c, mut r, '/f/p/x')
	assert st == 200
	want := 'HTTP/1.1 200 OK\r\nContent-Type: ${http1.ct_text}\r\nContent-Length: 4\r\n\r\n/p/x'.len
	req := 'GET /fx HTTP/1.1\r\nHost: x\r\n\r\n'
	mut buf := []u8{len: 4096}
	fd := c.sock.handle
	for _ in 0 .. 500 {
		roundtrip(fd, req, mut buf, want)
	}
	// Boehm counts small allocations a free-list block (~8 KiB) at a time, so a
	// few bytes a request would show up here once every few hundred requests
	before := http1.allocated_bytes()
	for _ in 0 .. 3000 {
		roundtrip(fd, req, mut buf, want)
	}
	assert http1.allocated_bytes() - before == 0
	c.close() or {}
}

fn test_fetch_through_a_pool() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{}, false)
	defer {
		stop.request()
	}
	mut c := dial(front)
	mut r := Reader{}
	for i in 0 .. 20 {
		st, body := get(mut c, mut r, '/f/p/x${i}')
		assert st == 200 && body == '/p/x${i}'
	}
	// pipelined: each waits its turn behind the fetch before it
	c.write_string('GET /f/p/a HTTP/1.1\r\nHost: x\r\n\r\nGET /f/p/b HTTP/1.1\r\nHost: x\r\n\r\n') or {
		panic(err)
	}
	_, a := r.response(mut c) or { panic(err) }
	_, b := r.response(mut c) or { panic(err) }
	assert a == '/p/a' && b == '/p/b'
	c.write_string('POST /f-post HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello') or {
		panic(err)
	}
	st, echoed := r.response(mut c) or { panic(err) }
	assert st == 200 && echoed == 'hello'
	st2, chained := get(mut c, mut r, '/f-chain')
	assert st2 == 200 && chained == '/p/two', chained
	// the upstream's own 404 comes through as it is
	st3, _ := get(mut c, mut r, '/f/nope')
	assert st3 == 404
	c.close() or {}
}

// One connection per worker to the upstream, many clients at once: the rest queue.
fn test_fetch_queues_past_max_conns() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{ max_conns: 1 }, false)
	defer {
		stop.request()
	}
	ch := chan string{cap: 16}
	for i in 0 .. 16 {
		spawn fn [front, i, ch] () {
			mut c := dial(front)
			mut r := Reader{}
			_, body := get(mut c, mut r, '/f/delay/${20 + i}')
			ch <- body
			c.close() or {}
		}()
	}
	mut got := map[string]bool{}
	for _ in 0 .. 16 {
		got[<-ch] = true
	}
	for i in 0 .. 16 {
		assert '${20 + i}' in got, '${got}'
	}
}

fn test_fetch_errors() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	// timeout: checked once a second, so 1 s answers within about 2
	front, mut stop := start_front(up, UpstreamOptions{
		timeout:   time.second
		max_reply: 1000
	}, false)
	defer {
		stop.request()
	}
	mut c := dial(front)
	mut r := Reader{}
	t0 := time.sys_mono_now()
	st, body := get(mut c, mut r, '/f/delay/4000')
	assert st == 599 && body == 'timeout'
	assert time.sys_mono_now() - t0 < 3500 * u64(time.millisecond)
	// the connection that timed out is closed; the next fetch gets a new one
	st2, body2 := get(mut c, mut r, '/f/p/ok')
	assert st2 == 200 && body2 == '/p/ok'
	st3, body3 := get(mut c, mut r, '/f/big')
	assert st3 == 599 && body3 == 'too_big'
	c.close() or {}
	// nobody listening
	front2, mut stop2 := start_front(free_addr(), UpstreamOptions{}, false)
	defer {
		stop2.request()
	}
	mut c2 := dial(front2)
	mut r2 := Reader{}
	st4, body4 := get(mut c2, mut r2, '/f/p/x')
	assert st4 == 599 && body4 == 'connect'
	c2.close() or {}
}

// raw_upstream answers the n-th request on each connection with script(n): the
// bytes to write, and whether to close after them.
fn raw_upstream(script fn (n int) (string, bool)) string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := (l.addr() or { panic(err) }).str()
	spawn fn [l, script] () {
		mut ln := l
		for {
			conn := ln.accept() or { return }
			spawn fn [conn, script] () {
				mut c := conn
				mut acc := []u8{}
				mut tmp := []u8{len: 4096}
				mut n := 0
				for {
					end := head_end(acc)
					if end < 0 {
						k := c.read(mut tmp) or { 0 }
						if k <= 0 {
							c.close() or {}
							return
						}
						acc << tmp[..k]
						continue
					}
					acc = acc[end..].clone()
					n++
					reply, close := script(n)
					if reply.len > 0 {
						c.write_string(reply) or {}
					}
					if close {
						c.close() or {}
						return
					}
				}
			}()
		}
	}()
	return addr
}

fn script_retry(n int) (string, bool) {
	// the second request on a connection finds it closed, as a pooled connection the
	// upstream timed out just as it was taken would be
	if n == 1 {
		return 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok', false
	}
	return '', true
}

fn test_fetch_retries_a_pooled_connection_once() {
	up := raw_upstream(script_retry)
	front, mut stop := start_front(up, UpstreamOptions{ max_conns: 1 }, false)
	defer {
		stop.request()
	}
	mut c := dial(front)
	mut r := Reader{}
	for _ in 0 .. 3 {
		st, body := get(mut c, mut r, '/f/x')
		assert st == 200 && body == 'ok'
	}
	// a POST is not sent twice
	c.write_string('POST /f-post HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\nx') or {
		panic(err)
	}
	st, body := r.response(mut c) or { panic(err) }
	assert st == 599 && body == 'closed'
	c.close() or {}
}

fn script_shapes(n int) (string, bool) {
	return match n {
		1 { 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\nContent-Type: a/b\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n', false }
		2 { 'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 4\r\n\r\nlast', true }
		else { '', true }
	}
}

fn script_until_close(n int) (string, bool) {
	return 'HTTP/1.0 200 OK\r\n\r\nto the end', true
}

fn script_garbage(n int) (string, bool) {
	return 'SSH-2.0-OpenSSH\r\n\r\n', true
}

fn script_cut(n int) (string, bool) {
	return 'HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhalf', true
}

fn test_fetch_reply_shapes() {
	cases := {
		'shapes':      script_shapes
		'until_close': script_until_close
		'garbage':     script_garbage
		'cut':         script_cut
	}
	for name, script in cases {
		front, mut stop := start_front(raw_upstream(script), UpstreamOptions{}, false)
		mut c := dial(front)
		mut r := Reader{}
		match name {
			'shapes' {
				st, body := get(mut c, mut r, '/f/x')
				assert st == 201 && body == 'abcde', body
				st2, body2 := get(mut c, mut r, '/f/x')
				assert st2 == 200 && body2 == 'last'
				// the upstream closed that one: the next fetch connects again
				st3, body3 := get(mut c, mut r, '/f/x')
				assert st3 == 201 && body3 == 'abcde'
			}
			'until_close' {
				st, body := get(mut c, mut r, '/f/x')
				assert st == 200 && body == 'to the end'
			}
			'garbage' {
				st, body := get(mut c, mut r, '/f/x')
				assert st == 599 && body == 'protocol'
			}
			'cut' {
				st, body := get(mut c, mut r, '/f/x')
				assert st == 599 && body == 'closed'
			}
			else {}
		}

		c.close() or {}
		stop.request()
	}
}

// early_upstream answers a POST as soon as its head is in, then reads nothing for
// a while: a reply that overtakes its request. Any other request gets 200 with the
// number of the connection it came on.
fn early_upstream() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := (l.addr() or { panic(err) }).str()
	spawn fn [l] () {
		mut ln := l
		mut k := 0
		for {
			conn := ln.accept() or { return }
			k++
			spawn fn [conn, k] () {
				mut c := conn
				mut acc := []u8{}
				mut tmp := []u8{len: 4096}
				for {
					end := head_end(acc)
					if end < 0 {
						n := c.read(mut tmp) or { 0 }
						if n <= 0 {
							c.close() or {}
							return
						}
						acc << tmp[..n]
						continue
					}
					if acc[..4].bytestr() == 'POST' {
						c.write_string('HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n') or {}
						time.sleep(500 * time.millisecond)
						for {
							n := c.read(mut tmp) or { 0 }
							if n <= 0 {
								break
							}
						}
						c.close() or {}
						return
					}
					acc = acc[end..].clone()
					c.write_string('HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n${k}') or {}
				}
			}()
		}
	}()
	return addr
}

fn start_front_opts(up_addr string, uo UpstreamOptions, o Options) (string, &Stop) {
	spec := new_upstream('http://${up_addr}', uo) or { panic(err) }
	return serve_on(front_router(), Options{
		...o
		upstreams: [spec]
	}, false)
}

// A reply that arrives while the request is still going out must not leave the
// connection in the pool: the next fetch would land in the middle of that request.
fn test_early_reply_closes_the_connection() {
	front, mut stop := start_front_opts(early_upstream(), UpstreamOptions{ max_conns: 1 }, Options{
		limits: http1.Limits{
			max_body_bytes: 64 * 1024 * 1024
		}
	})
	defer {
		stop.request()
	}
	mut c := dial(front)
	mut r := Reader{}
	body := 'x'.repeat(32 * 1024 * 1024)
	c.write_string('POST /f-post HTTP/1.1\r\nHost: x\r\nContent-Length: ${body.len}\r\n\r\n') or {
		panic(err)
	}
	c.write_string(body) or { panic(err) }
	st, _ := r.response(mut c) or { panic(err) }
	assert st == 401
	// the same client connection stays on its worker, so on the same pool
	st2, b2 := get(mut c, mut r, '/f/x')
	assert st2 == 200 && b2 == '2', b2
	c.close() or {}
}

fn script_many_interims(n int) (string, bool) {
	return 'HTTP/1.1 100 Continue\r\n\r\n'.repeat(20) +
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok', true
}

// 40 one-byte chunks whose size lines carry 4000 bytes of extension each: 40 bytes of
// data, 160 KiB on the wire.
fn script_padded_chunks(n int) (string, bool) {
	chunk := '1;' + 'a'.repeat(4000) + '\r\nx\r\n'
	return 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' + chunk.repeat(40) + '0\r\n\r\n', false
}

fn test_fetch_hostile_replies_end_at_once() {
	front, mut stop := start_front(raw_upstream(script_many_interims), UpstreamOptions{}, false)
	mut c := dial(front)
	mut r := Reader{}
	st, body := get(mut c, mut r, '/f/x')
	assert st == 599 && body == 'protocol', body
	c.close() or {}
	stop.request()

	front2, mut stop2 := start_front(raw_upstream(script_padded_chunks), UpstreamOptions{
		max_reply: 1000
		timeout:   6 * time.second
	}, false)
	mut c2 := dial(front2)
	mut r2 := Reader{}
	t0 := time.sys_mono_now()
	st2, body2 := get(mut c2, mut r2, '/f/x')
	assert st2 == 599 && body2 == 'too_big', body2
	assert time.sys_mono_now() - t0 < 3 * u64(time.second)
	c2.close() or {}
	stop2.request()
}

// Over HTTP/2 a fetch holds only its own stream.
fn test_h2c_fetch() {
	v := sh('curl --version')
	if v.exit_code != 0 || !v.output.contains('HTTP2') {
		eprintln('skip: curl with HTTP/2 not found')
		return
	}
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{}, true)
	defer {
		stop.request()
	}
	urls := 'http://${front}/f/delay/300 http://${front}/f/p/fast'
	r :=
		sh('curl -s --http2-prior-knowledge --parallel -o /dev/null -o /dev/null -w "%{url_effective} %{response_code} %{http_version} %{num_connects} %{time_total}\\n" ${urls}')
	out := r.output
	lines := out.trim_space().split_into_lines()
	assert lines.len == 2, out
	mut connects := 0
	for line in lines {
		f := line.split(' ')
		assert f.len == 5 && f[1] == '200' && f[2] == '2', out
		connects += f[3].int()
		if f[0].ends_with('/p/fast') {
			assert f[4].f64() < 0.25, out
		} else {
			assert f[4].f64() >= 0.3, out
		}
	}
	assert connects == 1, out
}

// Past max_conns and max_queue a fetch answers .busy at once. Two workers with one
// connection each and no queue: of eight fetches at once, at most two get through.
fn test_fetch_busy_past_the_queue() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{ max_conns: 1, max_queue: 0 }, false)
	defer {
		stop.request()
	}
	ch := chan string{cap: 8}
	for _ in 0 .. 8 {
		spawn fn [front, ch] () {
			mut c := dial(front)
			mut r := Reader{}
			st, body := get(mut c, mut r, '/f/delay/400')
			ch <- '${st} ${body}'
			c.close() or {}
		}()
	}
	mut busy := 0
	mut ok := 0
	for _ in 0 .. 8 {
		got := <-ch
		if got == '599 busy' {
			busy++
		} else if got == '200 400' {
			ok++
		} else {
			assert false, got
		}
	}
	assert ok >= 1 && ok <= 2 && busy >= 6, '${ok} ok, ${busy} busy'
}

// A fetch that never got a connection times out in the queue, on its own deadline.
fn test_queued_fetch_times_out() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{
		max_conns: 1
		timeout:   time.second
	}, false)
	defer {
		stop.request()
	}
	t0 := time.sys_mono_now()
	ch := chan string{cap: 6}
	for _ in 0 .. 6 {
		spawn fn [front, ch] () {
			mut c := dial(front)
			mut r := Reader{}
			st, body := get(mut c, mut r, '/f/delay/6000')
			ch <- '${st} ${body}'
			c.close() or {}
		}()
	}
	for _ in 0 .. 6 {
		got := <-ch
		assert got == '599 timeout', got
	}
	// in flight or queued, each answered about a second in (the sweep runs once a
	// second), none after the upstream's six
	assert time.sys_mono_now() - t0 < 5900 * u64(time.millisecond)
}

fn script_ordinal(n int) (string, bool) {
	return 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n${n}', false
}

// A pooled connection idle past idle_timeout is closed: the next fetch opens a new
// one, where the scripted upstream counts from 1 again.
fn test_idle_peer_is_closed() {
	front, mut stop := start_front(raw_upstream(script_ordinal), UpstreamOptions{
		idle_timeout: time.second
	}, false)
	defer {
		stop.request()
	}
	mut c := dial(front)
	mut r := Reader{}
	_, a := get(mut c, mut r, '/f/x')
	_, b := get(mut c, mut r, '/f/x')
	assert a == '1' && b == '2', '${a} ${b}' // the second reused the connection
	time.sleep(2500 * time.millisecond)
	_, d := get(mut c, mut r, '/f/x')
	assert d == '1', d
	c.close() or {}
}

// A client that leaves while its fetch is out costs nothing: the reply is dropped
// and the server and its pool go on.
fn test_client_gone_mid_fetch() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{ max_conns: 1 }, false)
	defer {
		stop.request()
	}
	for _ in 0 .. 4 {
		mut c := dial(front)
		c.write_string('GET /f/delay/200 HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
		c.close() or {}
	}
	time.sleep(500 * time.millisecond)
	for i in 0 .. 8 {
		mut c := dial(front)
		mut r := Reader{}
		st, body := get(mut c, mut r, '/f/p/ok${i}')
		assert st == 200 && body == '/p/ok${i}', body
		c.close() or {}
	}
}
