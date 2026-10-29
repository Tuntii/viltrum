module engine

import os
import viltrum.http1
import viltrum.router

struct Item {
	id    int
	name  string
	price int
	tags  []string
}

struct Page {
	items []Item
	count int
}

fn make_items() []Item {
	mut a := []Item{}
	for i in 0 .. 20 {
		a << Item{
			id:    i
			name:  'Item number ${i}'
			price: i * 3
			tags:  ['tag-a', 'tag-b']
		}
	}
	return a
}

const items = make_items()

fn first_items(n int) []Item {
	mut v := unsafe { items }
	unsafe {
		v.len = if n < items.len { n } else { items.len }
	}
	return v
}

fn baseline(mut c http1.Ctx) {
	sum := (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }) + (c.body_int() or { 0 })
	c.text_int(200, sum)
}

fn pipeline(mut c http1.Ctx) {
	c.text(200, 'ok')
}

fn json_page(mut c http1.Ctx) {
	n := int(c.param_int('count') or { 0 })
	c.json(200, Page{
		items: first_items(n)
		count: n
	})
}

fn silent(mut c http1.Ctx) {}

fn delay_done(mut c http1.Ctx, ms u64) {
	c.text_int(200, i64(ms))
}

fn delay(mut c http1.Ctx) {
	ms := c.param_int('ms') or { 0 }
	c.after(int(ms), delay_done, u64(ms))
}

fn make_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/baseline11', [http1.Handler(baseline)]) or { panic(err) }
	r.add(.post, '/baseline11', [http1.Handler(baseline)]) or { panic(err) }
	r.add(.get, '/pipeline', [http1.Handler(pipeline)]) or { panic(err) }
	r.add(.get, '/json/:count', [http1.Handler(json_page)]) or { panic(err) }
	r.add(.get, '/gz/:count', [http1.Handler(http1.gzip_middleware), http1.Handler(json_page)]) or {
		panic(err)
	}
	r.add(.get, '/silent', [http1.Handler(silent)]) or { panic(err) }
	r.add(.get, '/delay/:ms', [http1.Handler(delay)]) or { panic(err) }
	r.add(.get, '/rdelay/:ms', [http1.Handler(http1.gzip_middleware), http1.Handler(delay)]) or {
		panic(err)
	}
	return r
}

fn run(mut w Worker, mut c Conn, req []u8) {
	unsafe {
		c.rbuf.len = 0
		c.wbuf.len = 0
		c.rbuf.push_many(req.data, req.len)
	}
	c.close_after = false
	c.frame.reset()
	w.process(mut c)
}

const shapes = {
	'get':          'GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: x\r\n\r\n'
	'get_escaped':  'GET /baseline11?%61=1%33&b=4%32 HTTP/1.1\r\nHost: x\r\n\r\n'
	'post_cl':      'POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n20'
	'post_chunked': 'POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n20\r\n0\r\n\r\n'
	'pipelined':    'GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'.repeat(16)
	'json':         'GET /json/10 HTTP/1.1\r\nHost: x\r\n\r\n'
	'json_gzip':    'GET /gz/10 HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, br\r\n\r\n'
	'crlf_between': 'POST /baseline11 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n20\r\nGET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'
}

fn test_each_shape_is_answered() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c, shapes['get'].bytes())
	assert c.wbuf.bytestr() == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\n55'
	run(mut w, mut c, shapes['get_escaped'].bytes())
	assert c.wbuf.bytestr().ends_with('\r\n\r\n55')
	run(mut w, mut c, shapes['post_cl'].bytes())
	assert c.wbuf.bytestr().ends_with('\r\n\r\n75')
	run(mut w, mut c, shapes['post_chunked'].bytes())
	assert c.wbuf.bytestr().ends_with('\r\n\r\n75')
	run(mut w, mut c, shapes['pipelined'].bytes())
	assert c.wbuf.bytestr().count('\r\n\r\nok') == 16
	run(mut w, mut c, shapes['json'].bytes())
	assert c.wbuf.bytestr().contains('"count":10}')
	run(mut w, mut c, shapes['json_gzip'].bytes())
	assert c.wbuf.bytestr().contains('Content-Encoding: gzip\r\n')
	assert c.rbuf.len == 0 && !c.close_after
}

// The acceptance gate of the whole rewrite: once buffers have grown to their working
// size, serving a request allocates nothing on the GC heap.
fn test_hot_path_allocates_nothing() {
	mut w := new_worker(make_router(), Options{}, 0)
	mut c := new_conn()
	for name, raw in shapes {
		req := raw.bytes()
		for _ in 0 .. 200 {
			run(mut w, mut c, req)
		}
		before := http1.allocated_bytes()
		for _ in 0 .. 10000 {
			run(mut w, mut c, req)
		}
		assert http1.allocated_bytes() - before == 0, '${name} allocates'
	}
}

// Review Focus 1: a handler that never responds still produces a response.
fn test_silent_handler_gets_500_and_close() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c,
		'GET /silent HTTP/1.1\r\nHost: x\r\n\r\nGET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	s := c.wbuf.bytestr()
	assert s.starts_with('HTTP/1.1 500 Internal Server Error\r\n')
	assert s.contains('Connection: close\r\n') && s.count('HTTP/1.1') == 1
	assert c.close_after
}

fn test_bad_request_mid_pipeline() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	ok := 'GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'
	run(mut w, mut c, (ok + ok + 'GET /pipeline HTTP/1.1\r\nHost : x\r\n\r\n' + ok).bytes())
	s := c.wbuf.bytestr()
	assert s.count('\r\n\r\nok') == 2
	assert s.contains('HTTP/1.1 400 Bad Request\r\n') && s.ends_with('bad header name')
	assert c.close_after && c.rbuf.len == 0
}

fn test_expect_continue_and_partial_requests() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c,
		'POST /baseline11?a=1&b=2 HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n'.bytes())
	assert c.wbuf.bytestr() == 'HTTP/1.1 100 Continue\r\n\r\n'
	assert c.reading && c.rbuf.len > 0
	unsafe {
		c.wbuf.len = 0
	}
	c.rbuf << '20'.bytes()
	w.process(mut c)
	assert c.wbuf.bytestr().ends_with('\r\n\r\n23')
	assert !c.reading && c.rbuf.len == 0
}

fn test_no_continue_for_http10() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c,
		'POST /baseline11?a=1&b=2 HTTP/1.0\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n'.bytes())
	assert !c.wbuf.bytestr().contains('100 Continue')
	c.rbuf << '20'.bytes()
	w.process(mut c)
	assert c.wbuf.bytestr().ends_with('\r\n\r\n23') && !c.wbuf.bytestr().contains('100 Continue')
}

fn test_empty_lines_before_a_request_are_ignored() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	ok := 'GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'
	// a CRLF after a POST body, and two before the next request
	post := 'POST /baseline11?a=1&b=2 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n20'
	run(mut w, mut c, (post + '\r\n\r\n\r\n' + ok).bytes())
	s := c.wbuf.bytestr()
	assert s.count('HTTP/1.1 200 OK') == 2 && s.contains('\r\n\r\n23') && s.ends_with('\r\n\r\nok')
	assert c.rbuf.len == 0 && !c.reading && !c.close_after
	// only empty lines buffered: nothing to answer, nothing partial
	run(mut w, mut c, '\r\n\r\n'.bytes())
	assert c.wbuf.len == 0 && c.rbuf.len == 0 && !c.reading
	// a CR waits for its LF
	run(mut w, mut c, '\r'.bytes())
	assert c.wbuf.len == 0 && c.reading
	c.rbuf << ('\n' + ok).bytes()
	w.process(mut c)
	assert c.wbuf.bytestr().ends_with('\r\n\r\nok') && c.rbuf.len == 0
	// an HTTP/1.0 request behind an empty line still gets no 100 Continue
	run(mut w, mut c,
		'\r\nPOST /baseline11?a=1&b=2 HTTP/1.0\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n'.bytes())
	assert c.wbuf.len == 0
}

fn test_misses_and_missing_host() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c, 'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().starts_with('HTTP/1.1 404 Not Found\r\n')
	run(mut w, mut c, 'DELETE /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().starts_with('HTTP/1.1 405 Method Not Allowed\r\n')
	run(mut w, mut c, 'GET /pipeline HTTP/1.1\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().starts_with('HTTP/1.1 400 Bad Request\r\n') && c.close_after
	run(mut w, mut c, 'GET /pipeline HTTP/1.0\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().ends_with('ok') && c.close_after
}

fn test_pipelining_pauses_at_max_pending() {
	mut w := new_worker(make_router(), Options{
		send_date:   false
		max_pending: 200
	}, 0)
	mut c := new_conn()
	run(mut w, mut c, shapes['pipelined'].bytes())
	first := c.wbuf.bytestr().count('\r\n\r\nok')
	assert first > 0 && first < 16
	mut total := first
	for total < 16 {
		unsafe {
			c.wbuf.len = 0
		}
		w.process(mut c)
		total += c.wbuf.bytestr().count('\r\n\r\nok')
	}
	assert total == 16 && c.rbuf.len == 0
}

fn test_deferred_response_keeps_pipeline_order() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c,
		'GET /delay/5 HTTP/1.1\r\nHost: x\r\n\r\nGET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	assert c.waiting && c.wbuf.len == 0 && c.rbuf.len > 0 && !c.close_after
	assert w.timers.a.len == 1 && w.timers.a[0].fd == c.fd && w.timers.a[0].gen == c.gen
	w.resume(mut c)
	w.process(mut c)
	assert c.wbuf.bytestr() ==
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 1\r\n\r\n5' +
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\nok'
	assert !c.waiting && c.rbuf.len == 0
}

// Connection: close holds until the deferred response is written, then applies.
fn test_deferred_response_with_close() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c, 'GET /rdelay/7 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'.bytes())
	assert c.waiting && !c.close_after
	w.resume(mut c)
	s := c.wbuf.bytestr()
	assert s.contains('Connection: close\r\n') && s.ends_with('\r\n\r\n7') && c.close_after
}

fn test_deferred_zero_answers_at_once() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	run(mut w, mut c, 'GET /delay/0 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	assert !c.waiting && c.wbuf.bytestr().ends_with('\r\n\r\n0') && w.timers.a.len == 0
}

fn test_deferred_response_allocates_nothing() {
	mut w := new_worker(make_router(), Options{}, 0)
	mut c := new_conn()
	req := 'GET /delay/10 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	for _ in 0 .. 200 {
		run(mut w, mut c, req)
		w.resume(mut c)
		_ = w.timers.pop()
	}
	before := http1.allocated_bytes()
	for _ in 0 .. 10000 {
		run(mut w, mut c, req)
		w.resume(mut c)
		_ = w.timers.pop()
	}
	assert http1.allocated_bytes() - before == 0
}

// File answers too, once pbuf and the Conn's buffers are grown: a small file, a 304,
// a range, a directory index, a streamed file (closed after each run), a 404.
fn test_file_answers_allocate_nothing() {
	dir := os.join_path(os.temp_dir(), 'viltrum-alloc-${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'sub')) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'a.css'), 'x'.repeat(3000)) or { panic(err) }
	os.write_file(os.join_path(dir, 'sub', 'index.html'), '<p>i</p>') or { panic(err) }
	os.write_file(os.join_path(dir, 'big.bin'), 'y'.repeat(http1.file_inline_max + 1)) or {
		panic(err)
	}
	mut r := &router.Router{}
	r.add(.get, '/s/*filepath', [
		http1.Handler(fn [dir] (mut c http1.Ctx) {
			c.static_file(dir, c.param('filepath') or { '' })
		}),
	]) or { panic(err) }
	mut w := new_worker(r, Options{}, 0)
	mut c := new_conn()
	run(mut w, mut c, 'GET /s/a.css HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	etag := c.wbuf.bytestr().all_after('ETag: ').all_before('\r\n')
	reqs := {
		'small': 'GET /s/a.css HTTP/1.1\r\nHost: x\r\n\r\n'
		'304':   'GET /s/a.css HTTP/1.1\r\nHost: x\r\nIf-None-Match: ${etag}\r\n\r\n'
		'range': 'GET /s/a.css HTTP/1.1\r\nHost: x\r\nRange: bytes=10-19\r\n\r\n'
		'index': 'GET /s/sub/ HTTP/1.1\r\nHost: x\r\n\r\n'
		'big':   'GET /s/big.bin HTTP/1.1\r\nHost: x\r\n\r\n'
		'404':   'GET /s/missing.txt HTTP/1.1\r\nHost: x\r\n\r\n'
	}
	for name, raw in reqs {
		req := raw.bytes()
		for _ in 0 .. 200 {
			run(mut w, mut c, req)
			c.end_file()
		}
		before := http1.allocated_bytes()
		for _ in 0 .. 5000 {
			run(mut w, mut c, req)
			c.end_file()
		}
		assert http1.allocated_bytes() - before == 0, '${name} allocates'
	}
	run(mut w, mut c, reqs['304'].bytes())
	assert c.wbuf.bytestr().starts_with('HTTP/1.1 304 ')
	run(mut w, mut c, reqs['big'].bytes())
	assert c.file_fd >= 0 && c.file_left == http1.file_inline_max + 1
	c.end_file()
}

// serve_lent is one event as the event loop handles it: buffers lent, the request
// read and served, its response written out, the empty buffers taken back.
fn serve_lent(mut w Worker, mut c Conn, req []u8) string {
	w.lend(mut c)
	unsafe { c.rbuf.push_many(req.data, req.len) }
	w.process(mut c)
	out := c.wbuf.bytestr()
	unsafe {
		c.wbuf.len = 0
	}
	w.settle(mut c)
	return out
}

// A connection holds buffers only while something is in them: once its request is
// answered and out it holds none, and the next event borrows them back.
fn test_quiet_connection_holds_no_buffers() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut c := &Conn{}
	assert c.rbuf.cap == 0 && c.wbuf.cap == 0
	out := serve_lent(mut w, mut c, shapes['get'].bytes())
	assert out.ends_with('\r\n\r\n55')
	assert c.rbuf.cap == 0 && c.wbuf.cap == 0 && w.rpool.n == 1 && w.wpool.n == 1
	// a request cut short keeps its read buffer until the rest comes; the write buffer,
	// empty, goes back
	req := shapes['get'].bytes()
	assert serve_lent(mut w, mut c, req[..10]) == ''
	assert c.rbuf.len == 10 && c.rbuf.cap > 0 && c.wbuf.cap == 0 && w.rpool.n == 0
	assert serve_lent(mut w, mut c, req[10..]).ends_with('\r\n\r\n55')
	assert c.rbuf.cap == 0 && w.rpool.n == 1
	// output the socket has not taken keeps the write buffer
	w.lend(mut c)
	unsafe { c.rbuf.push_many(req.data, req.len) }
	w.process(mut c)
	c.out_armed = true
	w.settle(mut c)
	assert c.wbuf.len > 0 && c.wbuf.cap > 0 && c.rbuf.cap == 0
	// a buffer one response grew past what is worth keeping is not pooled
	c.out_armed = false
	unsafe { c.wbuf.grow_cap(shrink_wbuf_above) }
	unsafe {
		c.wbuf.len = 0
	}
	pooled := w.wpool.n
	w.settle(mut c)
	assert c.wbuf.cap == 0 && w.wpool.n == pooled
}

// Many quiet connections share a few buffers: served one after another, they never
// hold more than one pair between them.
fn test_quiet_connections_share_the_pool() {
	mut w := new_worker(make_router(), Options{ send_date: false }, 0)
	mut conns := []&Conn{}
	for _ in 0 .. 100 {
		conns << &Conn{}
	}
	for _ in 0 .. 3 {
		for mut c in conns {
			assert serve_lent(mut w, mut c, shapes['pipelined'].bytes()).count('\r\n\r\nok') == 16
		}
	}
	assert w.rpool.n == 1 && w.wpool.n == 1
	assert conns.all(it.rbuf.cap == 0 && it.wbuf.cap == 0)
}

// Lending and taking back allocate nothing once the pools hold a buffer of each.
fn test_lent_buffers_allocate_nothing() {
	mut w := new_worker(make_router(), Options{}, 0)
	mut a := &Conn{}
	mut pair := [a, &Conn{}]
	for name, raw in shapes {
		req := raw.bytes()
		for _ in 0 .. 200 {
			serve_lent(mut w, mut a, req)
		}
		before := http1.allocated_bytes()
		for _ in 0 .. 5000 {
			for mut c in pair {
				w.lend(mut c)
				unsafe { c.rbuf.push_many(req.data, req.len) }
				w.process(mut c)
				unsafe {
					c.wbuf.len = 0
				}
				w.settle(mut c)
			}
		}
		assert http1.allocated_bytes() - before == 0, '${name} allocates'
	}
}

// Limits.max_headers is enforced: more fields than that answer 431 and close.
fn test_max_headers_limit() {
	mut w := new_worker(make_router(), Options{
		send_date: false
		limits:    http1.Limits{
			max_headers: 4
		}
	}, 0)
	mut c := new_conn()
	run(mut w, mut c, 'GET /pipeline HTTP/1.1\r\nHost: x\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().ends_with('ok') && !c.close_after
	run(mut w, mut c,
		'GET /pipeline HTTP/1.1\r\nHost: x\r\nA: 1\r\nB: 2\r\nC: 3\r\nD: 4\r\n\r\n'.bytes())
	assert c.wbuf.bytestr().starts_with('HTTP/1.1 431 ') && c.close_after
}
