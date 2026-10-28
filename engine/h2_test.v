module engine

import os
import rand
import time
import viltrum.http1
import viltrum.http2
import viltrum.router

// HTTP/2 on the worker, driven through process like the HTTP/1.1 tests: frames in
// through c.rbuf, frames out of c.wbuf, decoded by a small client built on http2.

fn h2_sum(mut c http1.Ctx) {
	c.text_int(200, (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }))
}

fn h2_echo(mut c http1.Ctx) {
	c.bytes(200, 'application/octet-stream', c.body())
}

fn h2_big(mut c http1.Ctx) {
	c.bytes(200, 'application/octet-stream', big_body)
}

fn h2_headers_back(mut c http1.Ctx) {
	c.set_header('X-Cookie', c.header('cookie') or { '' })
	c.set_header('Set-Cookie', 'k=v')
	c.text(200, c.header('host') or { '' })
}

fn h2_file(mut c http1.Ctx) {
	c.file(h2_file_path, http1.FileOptions{})
}

// h2_defer_cb defers again arg more times, then answers
fn h2_defer_cb(mut c http1.Ctx, arg u64) {
	if arg > 0 {
		c.after(1, h2_defer_cb, arg - 1)
		return
	}
	c.text(200, 'late')
}

fn h2_defer(mut c http1.Ctx) {
	c.set_header('X-Dropped', 'set before after') // dropped, as on HTTP/1.1
	c.after(10, h2_defer_cb, u64(c.query_int('n') or { 0 }))
}

fn h2_status(mut c http1.Ctx) {
	c.text(int(c.param_int('n') or { 200 }), 'x')
}

struct H2Counts {
mut:
	closed int
}

const h2_counts = &H2Counts{}

fn h2_st_closed(mut s http1.Stream) {
	mut k := unsafe { h2_counts }
	k.closed++
}

// h2_tick sends an event, arg more times, then ends the stream
fn h2_tick(mut s http1.Stream, arg u64) {
	if arg == 0 {
		s.end()
		return
	}
	s.event('tick', 'x')
	s.after(1, h2_tick, arg - 1)
}

fn h2_sse_open(mut s http1.Stream, mut c http1.Ctx) {
	s.event_id('1', 'hello', c.path())
	s.after(5, h2_tick, u64(c.query_int('n') or { 2 }))
}

const h2_sse_h = &http1.StreamHandler{
	on_open:  h2_sse_open
	on_close: h2_st_closed
}

// h2_gen_drain writes a piece each time the last one is out, five in all
fn h2_gen_drain(mut s http1.Stream) {
	n := u64(s.data)
	if n == 5 {
		s.end()
		return
	}
	s.write_string('chunk')
	s.data = voidptr(n + 1)
}

const h2_gen_h = &http1.StreamHandler{
	on_drain: h2_gen_drain
	on_close: h2_st_closed
}

fn h2_sub_open(mut s http1.Stream, mut c http1.Ctx) {
	s.subscribe('news')
}

const h2_sub_h = &http1.StreamHandler{
	on_open:   h2_sub_open
	on_close:  h2_st_closed
	heartbeat: 15 * time.second
}

fn h2_now_open(mut s http1.Stream, mut c http1.Ctx) {
	s.write_string('all')
	s.end()
}

const h2_now_h = &http1.StreamHandler{
	on_open:  h2_now_open
	on_close: h2_st_closed
}

fn h2_sse(mut c http1.Ctx) {
	c.sse(h2_sse_h)
}

fn h2_gen(mut c http1.Ctx) {
	c.stream(200, 'text/plain', h2_gen_h)
}

fn h2_sub(mut c http1.Ctx) {
	c.sse(h2_sub_h)
}

fn h2_now(mut c http1.Ctx) {
	c.stream(200, 'text/plain', h2_now_h)
}

const big_body = []u8{len: 100000, init: u8(index * 7)}
const h2_file_path = os.join_path(os.temp_dir(), 'viltrum_h2_file_test.bin')

fn h2_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/baseline2', [http1.Handler(h2_sum)]) or { panic(err) }
	r.add(.post, '/echo', [http1.Handler(h2_echo)]) or { panic(err) }
	r.add(.get, '/big', [http1.Handler(h2_big)]) or { panic(err) }
	r.add(.get, '/headers', [http1.Handler(h2_headers_back)]) or { panic(err) }
	r.add(.get, '/file', [http1.Handler(h2_file)]) or { panic(err) }
	r.add(.get, '/defer', [http1.Handler(h2_defer)]) or { panic(err) }
	r.add(.get, '/status/:n', [http1.Handler(h2_status)]) or { panic(err) }
	r.add(.get, '/sse', [http1.Handler(h2_sse)]) or { panic(err) }
	r.add(.get, '/gen', [http1.Handler(h2_gen)]) or { panic(err) }
	r.add(.get, '/sub', [http1.Handler(h2_sub)]) or { panic(err) }
	r.add(.get, '/now', [http1.Handler(h2_now)]) or { panic(err) }
	return r
}

struct Frame {
	typ     u8
	flags   u8
	stream  u32
	payload []u8
}

// Client is the test's side of a connection: its encoder and decoder.
struct Client {
mut:
	enc &http2.Encoder = http2.new_encoder(http2.default_table_size)
	dec &http2.Decoder = http2.new_decoder(http2.default_table_size)
}

fn frame(typ u8, flags u8, stream u32, payload []u8) []u8 {
	mut out := []u8{}
	http2.write_frame_header(mut out, payload.len, typ, flags, stream)
	out << payload
	return out
}

fn settings(params [][]u32) []u8 {
	mut p := []u8{}
	for kv in params {
		p << u8(kv[0] >> 8)
		p << u8(kv[0])
		http2.put_u32(mut p, kv[1])
	}
	return frame(http2.frame_settings, 0, 0, p)
}

fn window_update(stream u32, n u32) []u8 {
	mut p := []u8{}
	http2.put_u32(mut p, n)
	return frame(http2.frame_window_update, 0, stream, p)
}

// block encodes fields given as 'name: value' strings.
fn (mut cl Client) block(fields []string) []u8 {
	mut out := []u8{}
	cl.enc.begin(mut out)
	for f in fields {
		k := f.index(': ') or { panic(f) }
		cl.enc.field(mut out, f[..k], f[k + 2..], .incremental)
	}
	return out
}

fn (mut cl Client) get(stream u32, path string) []u8 {
	return frame(http2.frame_headers, http2.flag_end_headers | http2.flag_end_stream, stream, cl.block([
		':method: GET',
		':scheme: http',
		':path: ${path}',
		':authority: x',
	]))
}

// open is a fresh h2 connection: its preface and SETTINGS already read, our
// SETTINGS and its ACK taken off the output.
fn open(mut w Worker, params [][]u32) &Conn {
	mut c := new_conn()
	c.h2_ok = true
	mut b := http2.preface.bytes()
	b << settings(params)
	feed(mut w, mut c, b)
	out := take(mut w, mut c)
	fs := parse(out)
	assert fs.len >= 2 && fs[0].typ == http2.frame_settings && fs[0].flags == 0
	assert fs.any(it.typ == http2.frame_settings && it.flags == http2.flag_ack)
	return c
}

fn feed(mut w Worker, mut c Conn, b []u8) {
	c.rbuf << b
	for {
		before := c.rbuf.len
		w.process(mut c)
		if c.rbuf.len == before || c.close_after {
			break
		}
	}
}

// take is the output so far, as a socket that takes everything would get it: what
// h2_pump stages once wbuf is out included.
fn take(mut w Worker, mut c Conn) []u8 {
	mut out := c.wbuf.clone()
	c.wbuf.clear()
	for !isnil(c.h2) && w.h2_pump(mut c) {
		out << c.wbuf
		c.wbuf.clear()
	}
	return out
}

fn parse(b []u8) []Frame {
	mut fs := []Frame{}
	mut p := 0
	for p + 9 <= b.len {
		fh := http2.read_frame_header(unsafe { &u8(b.data) + p })
		assert p + 9 + fh.length <= b.len, 'a frame cut short'
		fs << Frame{
			typ:     fh.typ
			flags:   fh.flags
			stream:  fh.stream
			payload: b[p + 9..p + 9 + fh.length].clone()
		}
		p += 9 + fh.length
	}
	assert p == b.len
	return fs
}

struct Response {
mut:
	status  string
	headers map[string]string
	body    []u8
	ended   bool
	reset   u32 = 0xffffffff
}

// responses decodes the frames per stream, in order.
fn (mut cl Client) responses(fs []Frame) map[u32]Response {
	mut r := map[u32]Response{}
	for f in fs {
		if f.stream == 0 {
			continue
		}
		mut x := r[f.stream] or { Response{} }
		if f.typ == http2.frame_headers {
			mut out := []u8{}
			mut flds := http2.Fields{}
			assert cl.dec.decode(f.payload, mut out, mut flds, 1 << 20) == http2.hpack_ok
			for k in 0 .. flds.n {
				h := flds.f[k]
				name := out[h.name_off..h.name_off + h.name_len].bytestr()
				value := out[h.value_off..h.value_off + h.value_len].bytestr()
				if name == ':status' {
					x.status = value
				} else {
					x.headers[name] = value
				}
			}
			x.ended = f.flags & http2.flag_end_stream != 0
		} else if f.typ == http2.frame_data {
			assert !x.ended, 'DATA after END_STREAM'
			x.body << f.payload
			x.ended = f.flags & http2.flag_end_stream != 0
		} else if f.typ == http2.frame_rst_stream {
			x.reset = unsafe { http2.get_u32(&u8(f.payload.data)) }
		}
		r[f.stream] = x
	}
	return r
}

fn goaway_code(fs []Frame) i64 {
	for f in fs {
		if f.typ == http2.frame_goaway {
			return i64(unsafe { http2.get_u32(&u8(f.payload.data) + 4) })
		}
	}
	return -1
}

fn test_prior_knowledge_request() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	feed(mut w, mut c, cl.get(1, '/baseline2?a=13&b=42'))
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].status == '200' && r[1].body == '55'.bytes() && r[1].ended
	assert r[1].headers['content-type'] == 'text/plain; charset=utf-8'
	assert r[1].headers['content-length'] == '2'
	assert 'connection' !in r[1].headers
	assert !c.close_after && c.rbuf.len == 0
}

fn test_http1_on_an_h2_listener() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	c.h2_ok = true
	feed(mut w, mut c, 'GET /baseline2?a=1&b=2 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes())
	assert isnil(c.h2) && c.wbuf.bytestr().ends_with('\r\n\r\n3')
	// a preface that goes wrong after its first line is an HTTP/2 client refused
	mut c2 := new_conn()
	c2.h2_ok = true
	feed(mut w, mut c2, 'PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n'.bytes())
	assert goaway_code(parse(take(mut w, mut c2))) == http2.err_protocol && c2.close_after
}

fn test_many_streams_in_one_read() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := []u8{}
	for i in 0 .. 100 {
		b << cl.get(u32(2 * i + 1), '/baseline2?a=${i}&b=1')
	}
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r.len == 100
	for i in 0 .. 100 {
		assert r[u32(2 * i + 1)].body == '${i + 1}'.bytes()
	}
}

fn test_body_across_frames_and_trailers() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	body := []u8{len: 40000, init: u8(index)}
	mut b := frame(http2.frame_headers, http2.flag_end_headers, 1, cl.block([
		':method: POST',
		':scheme: http',
		':path: /echo',
		':authority: x',
		'content-length: 40000',
	]))
	b << frame(http2.frame_data, 0, 1, body[..15000])
	b << frame(http2.frame_data, http2.flag_padded, 1, [u8(3), 0, 0, 0]) // all padding
	feed(mut w, mut c, b)
	assert c.reading
	mut padded := [u8(4)]
	padded << body[15000..30000]
	padded << [u8(0), 0, 0, 0]
	mut b2 := frame(http2.frame_data, http2.flag_padded, 1, padded)
	b2 << frame(http2.frame_data, 0, 1, body[30000..])
	// trailers end it
	b2 << frame(http2.frame_headers, http2.flag_end_headers | http2.flag_end_stream, 1, cl.block([
		'x-trailer: t',
	]))
	feed(mut w, mut c, b2)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].status == '200' && r[1].body == body
	assert !c.reading
}

fn test_content_length_must_match() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := frame(http2.frame_headers, http2.flag_end_headers, 1, cl.block([
		':method: POST',
		':scheme: http',
		':path: /echo',
		':authority: x',
		'content-length: 5',
	]))
	b << frame(http2.frame_data, http2.flag_end_stream, 1, 'abc'.bytes())
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].reset == http2.err_protocol && r[1].status == ''
	// the connection goes on
	feed(mut w, mut c, cl.get(3, '/baseline2?a=1&b=1'))
	assert cl.responses(parse(take(mut w, mut c)))[3].body == '2'.bytes()
}

// Uploader sends bodies the way a client must: within the windows the server gives.
struct Uploader {
mut:
	cl       Client
	conn_win i64 = http2.default_window
	init_win i64 = http2.default_window
	win      map[u32]i64
	resp     map[u32]Response
}

// apply takes the server's frames: its initial stream window, window updates and
// responses. True when a window grew.
fn (mut u Uploader) apply(fs []Frame) bool {
	mut grew := false
	for f in fs {
		if f.typ == http2.frame_settings && f.flags == 0 {
			for k := 0; k + 6 <= f.payload.len; k += 6 {
				if (int(f.payload[k]) << 8 | int(f.payload[k + 1])) == http2.settings_initial_window_size {
					u.init_win = i64(unsafe { http2.get_u32(&u8(f.payload.data) + k + 2) })
				}
			}
		} else if f.typ == http2.frame_window_update {
			inc := i64(unsafe { http2.get_u32(&u8(f.payload.data)) })
			if f.stream == 0 {
				u.conn_win += inc
			} else {
				u.win[f.stream] = (u.win[f.stream] or { 0 }) + inc
			}
			grew = true
		}
	}
	for id, r in u.cl.responses(fs) {
		mut x := u.resp[id] or { Response{} }
		if r.status != '' {
			x.status = r.status
		}
		x.body << r.body
		x.ended = x.ended || r.ended
		if r.reset != 0xffffffff {
			x.reset = r.reset
		}
		u.resp[id] = x
	}
	return grew
}

// Ten bodies near the limit at once on one connection: each finishes. Were the
// connection window given back only as requests finish, they would share it out
// and none would.
fn test_parallel_uploads_finish() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := new_conn()
	c.h2_ok = true
	mut b := http2.preface.bytes()
	// the echoes come back whole: our windows for them are wide open
	b << settings([[u32(http2.settings_initial_window_size), u32(http2.max_window)]])
	b << window_update(0, u32(http2.max_window - http2.default_window))
	feed(mut w, mut c, b)
	mut u := Uploader{}
	u.apply(parse(take(mut w, mut c)))
	n := 10
	size := 900000
	body := []u8{len: size, init: u8(index * 31)}
	mut sent := []int{len: n}
	mut open := []u8{}
	for k in 0 .. n {
		id := u32(2 * k + 1)
		open << frame(http2.frame_headers, http2.flag_end_headers, id, u.cl.block([
			':method: POST',
			':scheme: http',
			':path: /echo',
			':authority: x',
			'content-length: ${size}',
		]))
		u.win[id] = u.init_win
	}
	feed(mut w, mut c, open)
	for _ in 0 .. 10000 {
		mut round := []u8{}
		for k in 0 .. n {
			id := u32(2 * k + 1)
			mut amount := i64(size - sent[k])
			for lim in [i64(http2.default_frame_size), u.win[id] or { 0 }, u.conn_win] {
				if lim < amount {
					amount = lim
				}
			}
			if amount <= 0 {
				continue
			}
			end := sent[k] + int(amount) == size
			round << frame(http2.frame_data, if end { http2.flag_end_stream } else { u8(0) }, id, body[sent[k]..
				sent[k] + int(amount)])
			sent[k] += int(amount)
			u.win[id] = (u.win[id] or { 0 }) - amount
			u.conn_win -= amount
		}
		if round.len > 0 {
			feed(mut w, mut c, round)
		}
		grew := u.apply(parse(take(mut w, mut c)))
		if round.len == 0 && !grew {
			break // nothing can move
		}
	}
	for k in 0 .. n {
		id := u32(2 * k + 1)
		assert sent[k] == size, 'stream ${id} stalled at ${sent[k]}'
		assert u.resp[id].status == '200' && u.resp[id].ended && u.resp[id].body == body
	}
	assert c.h2.open == 0 && c.h2.buffered == 0
}

// A body past the limit is answered 413 and its stream reset; others go on.
fn test_body_past_the_limit() {
	mut w := new_worker(h2_router(), Options{
		send_date: false
		limits:    http1.Limits{
			max_body_bytes: 1000
		}
	}, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := frame(http2.frame_headers, http2.flag_end_headers, 1, cl.block([
		':method: POST',
		':scheme: http',
		':path: /echo',
		':authority: x',
	]))
	b << frame(http2.frame_data, 0, 1, []u8{len: 1001})
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].status == '413' && r[1].reset == http2.err_no_error
	feed(mut w, mut c, cl.get(3, '/baseline2?a=1&b=1'))
	assert cl.responses(parse(take(mut w, mut c)))[3].body == '2'.bytes()
	assert c.h2.buffered == 0
}

// Window the client gives a stream while its body is still coming is the response's
// to use.
fn test_window_given_during_the_body_reaches_the_response() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [[u32(http2.settings_initial_window_size), 1000]])
	mut cl := Client{}
	body := []u8{len: 40000, init: u8(index)}
	mut b := frame(http2.frame_headers, http2.flag_end_headers, 1, cl.block([
		':method: POST',
		':scheme: http',
		':path: /echo',
		':authority: x',
	]))
	b << window_update(1, 100000)
	b << frame(http2.frame_data, 0, 1, body[..16000])
	b << frame(http2.frame_data, 0, 1, body[16000..32000])
	b << frame(http2.frame_data, http2.flag_end_stream, 1, body[32000..])
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].ended && r[1].body == body
}

// What waits on the client's windows is bounded like HTTP/1.1 output: past
// max_pending, new streams are refused (and the client may retry them).
fn test_held_output_is_bounded() {
	mut w := new_worker(h2_router(), Options{
		send_date:   false
		max_pending: 250000
	}, 0)
	mut c := open(mut w, [[u32(http2.settings_initial_window_size), 0]])
	mut cl := Client{}
	mut b := []u8{}
	for i in 0 .. 4 {
		b << cl.get(u32(2 * i + 1), '/big')
	}
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].status == '200' && r[5].status == '200'
	assert r[7].reset == http2.err_refused_stream
	assert c.h2.held == 3 * big_body.len && c.h2.sending == 3
	// a reset gives its share back
	mut p := []u8{}
	http2.put_u32(mut p, http2.err_cancel)
	feed(mut w, mut c, frame(http2.frame_rst_stream, 0, 1, p))
	assert c.h2.held == 2 * big_body.len && c.h2.sending == 2
}

// Trailers on a stream we already answered and reset were in flight, not an error.
fn test_frames_after_our_reset_are_ignored() {
	mut w := new_worker(h2_router(), Options{
		send_date: false
		limits:    http1.Limits{
			max_body_bytes: 100
		}
	}, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := frame(http2.frame_headers, http2.flag_end_headers, 1, cl.block([
		':method: POST',
		':scheme: http',
		':path: /echo',
		':authority: x',
	]))
	b << frame(http2.frame_data, 0, 1, []u8{len: 200})
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].status == '413' && r[1].reset == http2.err_no_error
	mut b2 := frame(http2.frame_data, 0, 1, []u8{len: 50})
	b2 << frame(http2.frame_headers, http2.flag_end_headers | http2.flag_end_stream, 1, cl.block([
		'x-trailer: t',
	]))
	b2 << cl.get(3, '/baseline2?a=1&b=2')
	feed(mut w, mut c, b2)
	fs := parse(take(mut w, mut c))
	assert goaway_code(fs) == -1 && !c.close_after
	r2 := cl.responses(fs)
	assert r2[3].body == '3'.bytes() && 1 !in r2
}

// A status HTTP/2 cannot carry ends the stream rather than the connection.
fn test_unsendable_status() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := cl.get(1, '/status/103')
	b << cl.get(3, '/status/1000')
	b << cl.get(5, '/status/204')
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].reset == http2.err_internal && r[3].reset == http2.err_internal
	assert r[5].status == '204' && r[5].ended
}

fn test_flow_control_holds_and_releases() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [[u32(http2.settings_initial_window_size), 1000]])
	mut cl := Client{}
	feed(mut w, mut c, cl.get(1, '/big'))
	mut fs := parse(take(mut w, mut c))
	mut r := cl.responses(fs)
	assert r[1].status == '200' && r[1].body.len == 1000 && !r[1].ended
	mut got := r[1].body.clone()
	// the stream window opens; the connection window (65535) then holds it
	feed(mut w, mut c, window_update(1, 200000))
	r = cl.responses(parse(take(mut w, mut c)))
	assert got.len + r[1].body.len == http2.default_window
	got << r[1].body
	feed(mut w, mut c, window_update(0, 200000))
	r = cl.responses(parse(take(mut w, mut c)))
	got << r[1].body
	assert r[1].ended && got == big_body
	assert c.h2.open == 0 && c.h2.sending == 0
}

fn test_file_answer_streams() {
	data := []u8{len: 150000, init: u8(index * 13)}
	os.write_file_array(h2_file_path, data) or { panic(err) }
	defer {
		os.rm(h2_file_path) or {}
	}
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := window_update(0, 1 << 20)
	b << cl.get(1, '/file')
	feed(mut w, mut c, b)
	mut r := cl.responses(parse(take(mut w, mut c)))
	mut got := r[1].body.clone()
	assert r[1].headers['content-length'] == '150000' && !r[1].ended
	feed(mut w, mut c, window_update(1, 1 << 20))
	r = cl.responses(parse(take(mut w, mut c)))
	got << r[1].body
	assert r[1].ended && got == data
	assert c.h2.open == 0 && c.h2.streams.all(it.file_fd < 0)
}

fn test_continuation() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	blk := cl.block([':method: GET', ':scheme: http', ':path: /headers', ':authority: example.org',
		'cookie: a=1', 'cookie: b=2', 'cookie: c=3'])
	mut b := frame(http2.frame_headers, http2.flag_end_stream, 1, blk[..5])
	b << frame(http2.frame_continuation, 0, 1, blk[5..9])
	b << frame(http2.frame_continuation, http2.flag_end_headers, 1, blk[9..])
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].body == 'example.org'.bytes()
	assert r[1].headers['x-cookie'] == 'a=1; b=2; c=3'
	assert r[1].headers['set-cookie'] == 'k=v'
	// another frame inside a header block ends the connection
	mut b2 := frame(http2.frame_headers, http2.flag_end_stream, 3, cl.block([
		':method: GET',
	]))
	b2 << settings([])
	feed(mut w, mut c, b2)
	assert goaway_code(parse(take(mut w, mut c))) == http2.err_protocol && c.close_after
}

fn test_malformed_requests_reset_the_stream() {
	cases := {
		'no path':            [':method: GET', ':scheme: http', ':authority: x']
		'pseudo after field': [':method: GET', ':scheme: http', 'a: 1', ':path: /baseline2']
		'unknown pseudo':     [':method: GET', ':scheme: http', ':path: /', ':status: 200']
		'connection field':   [':method: GET', ':scheme: http', ':path: /', 'connection: close']
		'te not trailers':    [':method: GET', ':scheme: http', ':path: /', 'te: gzip']
		'two methods':        [':method: GET', ':method: GET', ':scheme: http', ':path: /']
		'value with space':   [':method: GET', ':scheme: http', ':path: /', 'a:  x']
		'relative path':      [':method: GET', ':scheme: http', ':path: baseline2']
	}
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut id := u32(1)
	for name, fields in cases {
		feed(mut w, mut c, frame(http2.frame_headers,
			http2.flag_end_headers | http2.flag_end_stream, id, cl.block(fields)))
		r := cl.responses(parse(take(mut w, mut c)))
		assert r[id].reset == http2.err_protocol, name
		id += 2
	}
	// an uppercase name, which our encoder would never write: a literal without
	// indexing, its name spelled out
	mut blk := cl.block([':method: GET', ':scheme: http', ':path: /baseline2'])
	blk << [u8(0x00), 4, `X`, `-`, `U`, `p`, 1, `1`]
	feed(mut w, mut c, frame(http2.frame_headers, http2.flag_end_headers | http2.flag_end_stream,
		id, blk))
	assert cl.responses(parse(take(mut w, mut c)))[id].reset == http2.err_protocol
	id += 2
	feed(mut w, mut c, cl.get(id, '/baseline2?a=2&b=2'))
	assert cl.responses(parse(take(mut w, mut c)))[id].body == '4'.bytes()
}

fn test_stream_limit() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := []u8{}
	for i in 0 .. h2_max_streams + 1 {
		// bodies that never come keep the streams open
		b << frame(http2.frame_headers, http2.flag_end_headers, u32(2 * i + 1), cl.block([
			':method: POST',
			':scheme: http',
			':path: /echo',
			':authority: x',
		]))
	}
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r.len == 1 && r[u32(2 * h2_max_streams + 1)].reset == http2.err_refused_stream
	assert c.h2.open == h2_max_streams
	// a reset frees one
	mut p := []u8{}
	http2.put_u32(mut p, http2.err_cancel)
	feed(mut w, mut c, frame(http2.frame_rst_stream, 0, 1, p))
	assert c.h2.open == h2_max_streams - 1
}

fn test_connection_errors() {
	mut cl := Client{}
	cases := {
		'first frame not SETTINGS': frame(http2.frame_ping, 0, 0, []u8{len: 8})
		'DATA on stream 0':         frame(http2.frame_data, 0, 0, []u8{})
		'even stream':              cl.get(2, '/baseline2')
		'frame too large':          frame(http2.frame_data, 0, 1, []u8{len:
			http2.default_frame_size + 1})
		'bad HPACK':                frame(http2.frame_headers, http2.flag_end_headers, 1, [
			u8(0x80),
		])
		'window overflow':          window_update(0, 0x7fffffff)
		'zero increment':           window_update(0, 0)
		'push promise':             frame(http2.frame_push_promise, 0, 1, []u8{len: 4})
		'DATA on idle stream':      frame(http2.frame_data, 0, 9, 'x'.bytes())
		'bad SETTINGS length':      frame(http2.frame_settings, 0, 0, []u8{len: 5})
		'stray CONTINUATION':       frame(http2.frame_continuation, http2.flag_end_headers, 1,
			[]u8{})
	}
	codes := {
		'first frame not SETTINGS': http2.err_protocol
		'DATA on stream 0':         http2.err_protocol
		'even stream':              http2.err_protocol
		'frame too large':          http2.err_frame_size
		'bad HPACK':                http2.err_compression
		'window overflow':          http2.err_flow_control
		'zero increment':           http2.err_protocol
		'push promise':             http2.err_protocol
		'DATA on idle stream':      http2.err_protocol
		'bad SETTINGS length':      http2.err_frame_size
		'stray CONTINUATION':       http2.err_protocol
	}
	for name, b in cases {
		mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
		mut c := if name == 'first frame not SETTINGS' {
			mut x := new_conn()
			x.h2_ok = true
			mut pre := http2.preface.bytes()
			pre << b
			feed(mut w, mut x, pre)
			x
		} else {
			mut x := open(mut w, [])
			feed(mut w, mut x, b)
			x
		}
		assert goaway_code(parse(take(mut w, mut c))) == codes[name], name
		assert c.close_after, name
	}
}

fn test_ping_and_flood() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	feed(mut w, mut c, frame(http2.frame_ping, 0, 0, 'abcdefgh'.bytes()))
	fs := parse(take(mut w, mut c))
	assert fs.len == 1 && fs[0].typ == http2.frame_ping && fs[0].flags == http2.flag_ack
	assert fs[0].payload == 'abcdefgh'.bytes()
	mut b := []u8{}
	for _ in 0 .. h2_flood + 1 {
		b << frame(http2.frame_ping, 0, 0, 'abcdefgh'.bytes())
	}
	feed(mut w, mut c, b)
	assert goaway_code(parse(take(mut w, mut c))) == http2.err_enhance_your_calm
}

fn test_large_header_list_answers_431() {
	mut w := new_worker(h2_router(), Options{
		send_date: false
		limits:    http1.Limits{
			max_header_bytes: 1000
		}
	}, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	feed(mut w, mut c, frame(http2.frame_headers, http2.flag_end_headers | http2.flag_end_stream,
		1, cl.block([':method: GET', ':scheme: http', ':path: /baseline2?a=1&b=1', ':authority: x',
		'x-big: ${'y'.repeat(2000)}'])))
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].status == '431'
	// the decoder kept the table in step: the client's next block refers to entries
	// the refused one added
	feed(mut w, mut c, cl.get(3, '/baseline2?a=1&b=1'))
	assert cl.responses(parse(take(mut w, mut c)))[3].body == '2'.bytes()
}

// fire answers every deferred response on c, as the event loop does once each is due,
// without waiting for them; responses deferred again on the way are answered too.
fn fire(mut w Worker, mut c Conn) int {
	mut n := 0
	for w.timers.a.len > 0 {
		t := w.timers.pop()
		assert t.fd == c.fd && t.gen == c.gen && t.stream != 0
		if w.h2_resume(mut c, t.stream) {
			n++
		}
	}
	return n
}

// A deferred response waits on its own stream only: the streams after it are answered
// at once, and it follows when its timer is due, deferred again or not.
fn test_deferred_and_404() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := cl.get(1, '/defer')
	b << cl.get(3, '/nope')
	b << cl.get(5, '/defer?n=2')
	b << cl.get(7, '/baseline2?a=1&b=2')
	t0 := time.sys_mono_now()
	feed(mut w, mut c, b)
	r := cl.responses(parse(take(mut w, mut c)))
	assert 1 !in r && 5 !in r && r[3].status == '404' && r[7].body == '3'.bytes()
	assert c.h2.waiting == 2 && c.h2.open == 2 && c.h2_waits() && !c.reading
	assert w.timers.a.len == 2 && w.timers.a[0].due >= t0 + 10 * u64(time.millisecond)
	assert fire(mut w, mut c) == 4 // stream 5 waited three times
	r2 := cl.responses(parse(take(mut w, mut c)))
	for id in [u32(1), 5] {
		assert r2[id].status == '200' && r2[id].body == 'late'.bytes() && r2[id].ended
		assert 'x-dropped' !in r2[id].headers
	}
	assert c.h2.open == 0 && c.h2.waiting == 0 && !c.h2_waits() && !c.close_after
}

// The window a waiting stream gets meanwhile, from WINDOW_UPDATE and from a change of
// SETTINGS_INITIAL_WINDOW_SIZE, is the window its response goes out on.
fn test_deferred_follows_window() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [[u32(http2.settings_initial_window_size), 0]])
	mut cl := Client{}
	feed(mut w, mut c, cl.get(1, '/defer'))
	take(mut w, mut c)
	mut b := settings([[u32(http2.settings_initial_window_size), 1]])
	b << window_update(1, 2)
	feed(mut w, mut c, b)
	take(mut w, mut c)
	fire(mut w, mut c)
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[1].status == '200' && r[1].body == 'lat'.bytes() && !r[1].ended
	feed(mut w, mut c, window_update(1, 10))
	fs := parse(take(mut w, mut c))
	assert fs.len == 1 && fs[0].payload == 'e'.bytes() && fs[0].flags == http2.flag_end_stream
	assert c.h2.open == 0
}

// A stream the client resets while it waits drops its response: the timer finds
// nothing to answer, and the slot is free again.
fn test_deferred_stream_reset() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := cl.get(1, '/defer')
	b << frame(http2.frame_rst_stream, 0, 1, [u8(0), 0, 0, 8]) // CANCEL
	feed(mut w, mut c, b)
	assert c.h2.open == 0 && c.h2.waiting == 0 && !c.h2_waits()
	assert fire(mut w, mut c) == 0
	assert take(mut w, mut c).len == 0
	// a closing connection answers no deferred stream either
	feed(mut w, mut c, cl.get(3, '/defer'))
	w.h2_fail(mut c, http2.err_no_error)
	assert fire(mut w, mut c) == 0
}

// requests is n copies of frames on streams from id on, two apart: the client's
// block is the same bytes once its encoder has indexed the fields.
fn requests(mut cl Client, path string, id u32, n int, window bool) [][]u8 {
	mut out := [][]u8{}
	for k in 0 .. n {
		sid := id + u32(2 * k)
		mut b := cl.get(sid, path)
		if window {
			b << window_update(sid, 0x7fff0000)
		}
		out << b
	}
	return out
}

// The zero-allocation gate, for HTTP/2: once buffers and tables are warm, a request
// on an open connection allocates nothing, including one whose response flow
// control holds back on its stream.
fn test_h2_allocates_nothing() {
	for path in ['/baseline2?a=1&b=2', '/big'] {
		big := path == '/big'
		mut w := new_worker(h2_router(), Options{}, 0)
		mut c := open(mut w, [])
		mut cl := Client{}
		feed(mut w, mut c, window_update(0, 0x7fff0000))
		take(mut w, mut c)
		warm := requests(mut cl, path, 1, 200, big)
		reqs := requests(mut cl, path, 401, 5000, big)
		mut before := u64(0)
		for k, b in [warm, reqs] {
			if k == 1 {
				before = http1.allocated_bytes()
			}
			for req in b {
				unsafe { c.rbuf.push_many(req.data, req.len) }
				w.process(mut c)
				for {
					unsafe {
						c.wbuf.len = 0
					}
					if !w.h2_pump(mut c) {
						break
					}
				}
				if big {
					// the window update came after the HEADERS: the held rest goes now
					assert c.h2.open == 0
				}
			}
		}
		assert http1.allocated_bytes() - before == 0, '${path} allocates'
	}
}

// and a deferred response: parked on its stream, answered when its timer is due
fn test_h2_deferred_allocates_nothing() {
	mut w := new_worker(h2_router(), Options{}, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	warm := requests(mut cl, '/defer', 1, 200, false)
	reqs := requests(mut cl, '/defer', 401, 5000, false)
	mut before := u64(0)
	for k, b in [warm, reqs] {
		if k == 1 {
			before = http1.allocated_bytes()
		}
		for req in b {
			unsafe { c.rbuf.push_many(req.data, req.len) }
			w.process(mut c)
			t := w.timers.pop()
			assert w.h2_resume(mut c, t.stream)
			unsafe {
				c.wbuf.len = 0
			}
		}
	}
	assert http1.allocated_bytes() - before == 0
	assert c.h2.open == 0
}

// random frames and mutated good ones never upset the worker, and what it writes is
// always whole frames
fn test_h2_fuzz() {
	mut seeds := [][]u8{}
	mut cl := Client{}
	seeds << cl.get(1, '/baseline2?a=1&b=1')
	seeds << frame(http2.frame_headers, http2.flag_end_headers, 3, cl.block([
		':method: POST',
		':scheme: http',
		':path: /echo',
		':authority: x',
		'content-length: 3',
	]))
	seeds << frame(http2.frame_data, http2.flag_end_stream, 3, 'abc'.bytes())
	seeds << window_update(0, 1000)
	seeds << frame(http2.frame_ping, 0, 0, []u8{len: 8})
	seeds << settings([[u32(http2.settings_initial_window_size), 10]])
	seeds << frame(http2.frame_rst_stream, 0, 1, []u8{len: 4})
	seeds << cl.get(5, '/sse')
	seeds << cl.get(7, '/gen')
	seeds << cl.get(9, '/sub')
	n := os.getenv('VILTRUM_FUZZ_ITERS').int()
	iters := if n > 0 { n / 10 } else { 3000 }
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	for _ in 0 .. iters {
		mut c := open(mut w, [])
		mut b := []u8{}
		for _ in 0 .. 1 + rand.intn(6) or { 0 } {
			mut f := seeds[rand.intn(seeds.len) or { 0 }].clone()
			for _ in 0 .. rand.intn(3) or { 0 } {
				if f.len > 0 {
					f[rand.intn(f.len) or { 0 }] = u8(rand.intn(256) or { 0 })
				}
			}
			b << f
		}
		feed(mut w, mut c, b)
		parse(flow(mut w, mut c))
		parse(ticks(mut w, mut c))
		if !isnil(c.h2) {
			w.h2_end_streams(mut c)
			c.h2.close_streams()
		}
		assert w.topics.len == 0
	}
}

// --- streams (Ctx.stream) over HTTP/2 ---

// flow is the output so far as Loop.flush writes it to a socket that takes everything:
// held output as the windows allow, then what streams with nothing left to send
// generate, until neither moves.
fn flow(mut w Worker, mut c Conn) []u8 {
	mut out := take(mut w, mut c)
	for !isnil(c.h2) && (w.h2_drain(mut c) > 0 || c.wbuf.len > 0) {
		out << take(mut w, mut c)
	}
	return out
}

// ticks runs every stream timer as the event loop does once each is due, without
// waiting, and flows the output after each; timers set on the way run too.
fn ticks(mut w Worker, mut c Conn) []u8 {
	mut out := []u8{}
	for w.timers.a.len > 0 {
		t := w.timers.pop()
		if t.tick != 0 && w.st_tick(mut c, t.stream, t.cb(), t.arg) {
			out << flow(mut w, mut c)
		}
	}
	return out
}

fn rst(id u32) []u8 {
	return frame(http2.frame_rst_stream, 0, id, [u8(0), 0, 0, 8]) // CANCEL
}

// An SSE stream over HTTP/2: the head without END_STREAM, each event as its own DATA
// as on_open and the timers write it, END_STREAM once it ends, and on_close.
fn test_h2_sse_stream() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	closed := h2_counts.closed
	feed(mut w, mut c, cl.get(1, '/sse?n=2'))
	r := cl.responses(parse(flow(mut w, mut c)))
	assert r[1].status == '200' && !r[1].ended
	assert r[1].headers['content-type'] == 'text/event-stream'
	assert r[1].headers['cache-control'] == 'no-cache'
	assert 'transfer-encoding' !in r[1].headers && 'content-length' !in r[1].headers
	assert r[1].body == 'id: 1\nevent: hello\ndata: /sse\n\n'.bytes()
	assert c.h2.streaming == 1 && c.h2.open == 1 && c.h2_waits()
	fs := parse(ticks(mut w, mut c))
	assert fs.len == 3 && fs.all(it.typ == http2.frame_data && it.stream == 1)
	assert fs[0].payload == 'event: tick\ndata: x\n\n'.bytes() && fs[0].flags == 0
	assert fs[2].payload.len == 0 && fs[2].flags == http2.flag_end_stream
	assert c.h2.open == 0 && c.h2.streaming == 0 && !c.h2_waits()
	assert h2_counts.closed == closed + 1 && !c.close_after
}

// Many streams on one connection, each on its own HTTP/2 stream, and requests beside
// them answered at once.
fn test_h2_streams_share_the_connection() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := cl.get(1, '/sse?n=1')
	b << cl.get(3, '/sub')
	b << cl.get(5, '/baseline2?a=1&b=2')
	b << cl.get(7, '/sse?n=2')
	feed(mut w, mut c, b)
	r := cl.responses(parse(flow(mut w, mut c)))
	assert r[5].body == '3'.bytes() && r[5].ended
	assert !r[1].ended && !r[3].ended && !r[7].ended && r[3].body.len == 0
	assert c.h2.streaming == 3 && c.h2.open == 3
	// a request after them is not held up either
	feed(mut w, mut c, cl.get(9, '/baseline2?a=2&b=2'))
	assert cl.responses(parse(flow(mut w, mut c)))[9].body == '4'.bytes()
	r2 := cl.responses(parse(ticks(mut w, mut c)))
	assert r2[1].ended && r2[1].body == 'event: tick\ndata: x\n\n'.bytes()
	assert r2[7].ended && r2[7].body == 'event: tick\ndata: x\n\n'.repeat(2).bytes()
	assert 3 !in r2 && c.h2.streaming == 1 && c.h2.open == 1
	// the one left ends with its connection, and leaves its topic
	closed := h2_counts.closed
	w.h2_end_streams(mut c)
	c.h2.close_streams()
	assert c.h2.streaming == 0 && w.topics.len == 0 && h2_counts.closed == closed + 1
}

// A body generated as the client takes it: on_drain runs when the stream has nothing
// left to send, so it follows the stream's window.
fn test_h2_generated_stream_follows_the_window() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [[u32(http2.settings_initial_window_size), 7]])
	mut cl := Client{}
	closed := h2_counts.closed
	feed(mut w, mut c, cl.get(1, '/gen'))
	r := cl.responses(parse(flow(mut w, mut c)))
	// a piece, then two bytes of the next; the next waits for the rest to go
	assert r[1].status == '200' && r[1].body == 'chunkch'.bytes() && !r[1].ended
	assert c.h2.held == 3 && c.h2.sending == 1 && !c.h2_waits()
	assert flow(mut w, mut c).len == 0
	feed(mut w, mut c, window_update(1, 100))
	fs := parse(flow(mut w, mut c))
	mut body := r[1].body.clone()
	for f in fs {
		assert f.typ == http2.frame_data && f.stream == 1
		body << f.payload
	}
	assert body == 'chunk'.repeat(5).bytes() && fs.last().flags == http2.flag_end_stream
	assert c.h2.open == 0 && c.h2.held == 0 && c.h2.sending == 0
	assert h2_counts.closed == closed + 1
}

// A stream that writes and ends in on_open: its body and END_STREAM go at once. A HEAD
// request gets the head alone, with END_STREAM.
fn test_h2_stream_ended_at_once_and_head() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	closed := h2_counts.closed
	feed(mut w, mut c, cl.get(1, '/now'))
	feed(mut w, mut c, frame(http2.frame_headers, http2.flag_end_headers | http2.flag_end_stream,
		3, cl.block([':method: HEAD', ':scheme: http', ':path: /sse', ':authority: x'])))
	r := cl.responses(parse(flow(mut w, mut c)))
	assert r[1].body == 'all'.bytes() && r[1].ended
	assert r[3].status == '200' && r[3].ended && r[3].body.len == 0
	assert r[3].headers['content-type'] == 'text/event-stream'
	assert c.h2.open == 0 && c.h2.streaming == 0 && h2_counts.closed == closed + 1
	assert w.timers.a.len == 0 // the HEAD request never opened its stream
}

// A RST_STREAM from the client ends the stream as a closed connection does: on_close
// runs, it leaves its topics, and its timers find nothing.
fn test_h2_stream_reset_by_the_client() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	closed := h2_counts.closed
	mut b := cl.get(1, '/sub')
	b << cl.get(3, '/sse')
	feed(mut w, mut c, b)
	flow(mut w, mut c)
	assert c.h2.streaming == 2 && 'news' in w.topics
	mut rb := rst(1)
	rb << rst(3)
	feed(mut w, mut c, rb)
	assert c.h2.streaming == 0 && c.h2.open == 0 && 'news' !in w.topics
	assert h2_counts.closed == closed + 2
	assert ticks(mut w, mut c).len == 0
	assert flow(mut w, mut c).len == 0 && !c.close_after
}

// Bytes sent to one stream and published to a topic reach the HTTP/2 streams they are
// for; a publish skips only the stream it came from, not the others on its connection.
fn test_h2_send_and_publish_reach_streams() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	c.fd = 3
	mut cl := Client{}
	mut b := cl.get(1, '/sub')
	b << cl.get(3, '/sub')
	b << cl.get(5, '/gen')
	feed(mut w, mut c, b)
	flow(mut w, mut c)
	mut conns := [unsafe { &Conn(nil) }, unsafe { nil }, unsafe { nil }, c]
	one := http1.StreamId{
		worker: 0
		fd:     3
		gen:    c.gen
		stream: 1
	}
	mut touched := []&Conn{}
	posts := [
		http1.stream_post('', one, http1.StreamId{}, c'one', 3),
		http1.stream_post('news', http1.StreamId{}, one, c'two', 3),
		http1.sse_post('news', http1.StreamId{}, http1.StreamId{}, '', 'e', 'three') or {
			panic('sse_post')
		},
		// stream 5 has ended, 9 was never opened
		http1.stream_post('', http1.StreamId{ ...one, stream: 5 }, http1.StreamId{}, c'no', 2),
		http1.stream_post('', http1.StreamId{ ...one, stream: 9 }, http1.StreamId{}, c'no', 2),
		http1.ws_post('news', http1.WsId{}, http1.WsId{}, http1.ws_text, c'ws', 2),
	]
	for p in posts {
		w.deliver(p, mut conns, mut touched)
	}
	assert touched.len == 1 && c.touched
	r := cl.responses(parse(flow(mut w, mut c)))
	assert r[1].body == 'oneevent: e\ndata: three\n\n'.bytes()
	assert r[3].body == 'twoevent: e\ndata: three\n\n'.bytes()
	assert 5 !in r && !r[1].ended && !r[3].ended
}

// A stream whose client lets four times max_pending pile up behind its window is
// reset (CANCEL); the other streams on the connection, and in the topic, go on.
fn test_h2_slow_stream_is_reset() {
	mut w := new_worker(h2_router(), Options{
		send_date:   false
		max_pending: 1000
	}, 0)
	mut c := open(mut w, [[u32(http2.settings_initial_window_size), 0]])
	mut cl := Client{}
	closed := h2_counts.closed
	mut b := cl.get(1, '/sub')
	b << cl.get(3, '/sub')
	b << cl.get(5, '/sub')
	b << window_update(1, 1 << 20)
	b << window_update(5, 1 << 20)
	feed(mut w, mut c, b)
	flow(mut w, mut c)
	mut conns := [c]
	big := []u8{len: 1500}
	mut touched := []&Conn{}
	mut out := []u8{}
	for _ in 0 .. 3 {
		w.deliver(http1.stream_post('news', http1.StreamId{}, http1.StreamId{}, big.data, big.len), mut
			conns, mut touched)
		out << flow(mut w, mut c)
	}
	r := cl.responses(parse(out))
	assert r[3].reset == http2.err_cancel && r[3].body.len == 0
	assert r[1].body.len == 4500 && r[5].body.len == 4500 && r[1].reset == 0xffffffff
	assert c.h2.streaming == 2 && h2_counts.closed == closed + 1 && !c.close_after
	assert (w.topics['news'] or { panic('no topic') }).conns.len == 2
}

// A quiet SSE stream gets a comment once its handler's heartbeat passes.
fn test_h2_heartbeat() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	feed(mut w, mut c, cl.get(1, '/sub'))
	flow(mut w, mut c)
	last := c.h2.streams[c.h2.find(1)].st_last
	assert !w.h2_heartbeats(mut c, last + 14000)
	assert w.h2_heartbeats(mut c, last + 15000)
	fs := parse(flow(mut w, mut c))
	assert fs.len == 1 && fs[0].stream == 1 && fs[0].payload == ': \n\n'.bytes()
	assert !w.h2_heartbeats(mut c, last + 16000) // the comment counts as output
}

fn h2_alloc_tick(mut s http1.Stream, arg u64) {
	s.event('tick', 'x')
	s.after(1, h2_alloc_tick, arg)
}

// The zero-allocation gate, for streams over HTTP/2: once warm, a timer's event and a
// send to the stream allocate nothing.
fn test_h2_stream_allocates_nothing() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	c.fd = 0
	mut cl := Client{}
	mut b := cl.get(1, '/sub')
	b << window_update(0, 0x7fff0000)
	b << window_update(1, 0x7fff0000)
	feed(mut w, mut c, b)
	flow(mut w, mut c)
	mut conns := [c]
	me := http1.StreamId{
		fd:     0
		gen:    c.gen
		stream: 1
	}
	post := http1.stream_post('', me, http1.StreamId{}, c'data: x\n\n', 9)
	mut touched := []&Conn{}
	w.timers.push_tick(0, 0, c.gen, 1, h2_alloc_tick, 0)
	mut before := u64(0)
	for k in 0 .. 6000 {
		if k == 1000 {
			before = http1.allocated_bytes()
		}
		t := w.timers.pop()
		assert w.st_tick(mut c, t.stream, t.cb(), t.arg)
		w.deliver(post, mut conns, mut touched)
		touched.clear()
		c.touched = false
		for {
			unsafe {
				c.wbuf.len = 0
			}
			if !w.h2_pump(mut c) {
				break
			}
		}
	}
	assert http1.allocated_bytes() - before == 0
	assert c.h2.held == 0 && c.h2.streaming == 1
}
