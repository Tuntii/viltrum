module http1

struct Msg {
	message string
}

fn out_of(c Ctx) string {
	return c.out.bytestr()
}

fn test_request_accessors() {
	mut c :=
		test_ctx('POST /u/42/files?name=a%20b&flag&x=1+2&k%65y=v HTTP/1.1\r\nHost: h\r\nX-A: 1\r\nx-a: 2\r\nContent-Length: 3\r\n\r\n 7 ')!
	assert c.method() == .post
	assert c.path() == '/u/42/files'
	assert c.query() == 'name=a%20b&flag&x=1+2&k%65y=v'
	assert c.header('host')? == 'h'
	assert c.header('X-A')? == '1'
	mut it := c.header_values('x-a')
	mut vals := []string{}
	for {
		v := it.next() or { break }
		vals << v
	}
	assert vals == ['1', '2']
	assert c.query_param('name')? == 'a b'
	assert c.query_param('flag')? == ''
	assert c.query_param('x')? == '1 2'
	assert c.query_param('key')? == 'v'
	if _ := c.query_param('missing') {
		assert false
	}
	if _ := c.header('nope') {
		assert false
	}
	assert c.body_int()? == 7
	assert c.body().bytestr() == ' 7 '
	assert test_ctx('GET HTTP://h HTTP/1.1\r\nHost: h\r\n\r\n')!.path() == '/'
}

fn test_params() {
	mut c := test_ctx('GET /u/42 HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.param_names = ['id']
	c.params[0] = Span{
		start: c.head.path.start + 3
		len:   2
	}
	c.nparams = 1
	assert c.param('id')? == '42'
	assert c.param_int('id')? == 42
	if _ := c.param('other') {
		assert false
	}
}

// Review Focus 5: a decoded value stays correct after later decodes, even when the
// decode buffer has to grow.
fn test_decoded_values_survive_later_decodes() {
	long := '%41'.repeat(3000)
	mut c := test_ctx('GET /?a=%C3%A9t%C3%A9&b=${long} HTTP/1.1\r\nHost: h\r\n\r\n')!
	a := c.query_param('a')?
	b := c.query_param('b')?
	assert a == 'été'
	assert b == 'A'.repeat(3000)
	assert a == 'été'
	assert c.query_param('a')? == 'été'
}

fn test_chunked_body() {
	c :=
		test_ctx('POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n20\r\n0\r\n\r\n')!
	assert c.body_int()? == 20
}

fn test_text_response() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.text(200, 'hi')
	assert out_of(c) == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\nhi'
	assert c.status == 200 && c.responded
	c.text(500, 'again')
	assert out_of(c).ends_with('\r\n\r\nhi')
}

fn test_head_keeps_length_drops_body() {
	mut c := test_ctx('HEAD / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.text(200, 'hi')
	assert out_of(c).ends_with('Content-Length: 2\r\n\r\n')
}

fn test_connection_headers() {
	mut a := test_ctx('GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n')!
	a.text(200, 'x')
	assert out_of(a).contains('Connection: keep-alive\r\n')
	mut b := test_ctx('GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n')!
	b.text(200, 'x')
	assert out_of(b).contains('Connection: close\r\n') && b.close_after
	mut d := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	d.close()
	d.text(200, 'x')
	assert out_of(d).contains('Connection: close\r\n') && d.close_after
	mut e := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	e.text(200, 'x')
	assert !out_of(e).contains('Connection:')
}

fn test_extra_headers_date_and_server() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.send_date = true
	c.server = 'viltrum'
	c.set_header('X-Id', '7')
	assert c.has_header('x-id') && !c.has_header('vary')
	c.no_content(204)
	s := out_of(c)
	assert s.starts_with('HTTP/1.1 204 No Content\r\nX-Id: 7\r\nDate: ')
	assert s.ends_with(' GMT\r\nServer: viltrum\r\n\r\n')
	assert !s.contains('Content-Length')
}

fn test_text_int_json_bytes() {
	mut a := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	a.text_int(200, -42)
	assert out_of(a).ends_with('Content-Length: 3\r\n\r\n-42')
	mut b := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	b.json(200, Msg{ message: 'Hello, World!' })
	assert out_of(b) == 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{"message":"Hello, World!"}'
	mut d := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	d.bytes(201, 'application/octet-stream', [u8(1), 2])
	assert out_of(d).starts_with('HTTP/1.1 201 Created\r\nContent-Type: application/octet-stream\r\nContent-Length: 2\r\n')
}

fn test_invalid_headers_are_dropped() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.set_header('X-A', 'v\r\nSet-Cookie: x=1')
	c.set_header('X B', 'v')
	c.set_header('X:B', 'v')
	c.set_header('', 'v')
	c.set_header('X-Ok', 'fine')
	c.bytes(200, 'text/plain\r\nX-Evil: 1', [u8(`a`)])
	o := out_of(c)
	assert !o.contains('Set-Cookie') && !o.contains('X B') && !o.contains('X:B')
		&& !o.contains('X-Evil')
	assert o.contains('X-Ok: fine\r\n') && o.contains('Content-Type: application/octet-stream\r\n')
}

fn test_capture_holds_the_response() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.capture = true
	c.text(201, 'captured')
	assert c.out.len == 0
	assert c.captured_body().bytestr() == 'captured'
	c.capture = false
	c.send_captured(c.captured_body(), 'x-test')
	s := out_of(c)
	assert s.starts_with('HTTP/1.1 201 Created\r\n')
	assert s.contains('Content-Encoding: x-test\r\n') && s.ends_with('\r\n\r\ncaptured')
}

fn mw_one(mut c Ctx) {
	c.set_header('X-1', 'a')
	c.next()
}

fn mw_two(mut c Ctx) {
	c.set_header('X-2', 'b')
	c.next()
}

fn final_handler(mut c Ctx) {
	c.text(200, 'done')
}

fn test_chain_runs_in_order() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.chain = [Handler(mw_one), Handler(mw_two), Handler(final_handler)]
	c.chain[0](mut c)
	s := out_of(c)
	assert s.index('X-1')? < s.index('X-2')?
	assert s.ends_with('done')
}

fn baseline_handler(mut c Ctx) {
	sum := (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }) + (c.body_int() or { 0 })
	c.text_int(200, sum)
}

fn json_handler(mut c Ctx) {
	c.json(200, Msg{ message: 'Hello, World!' })
}

fn serve_once(mut c Ctx, raw []u8, f Frame, n int) {
	unsafe {
		c.out.len = 0
	}
	parse_head(raw, f.head_end, mut c.head) or { panic(err) }
	c.begin(view(raw, 0, n))
	c.set_body(view(raw, f.head_end, f.content_length))
	c.chain[0](mut c)
}

fn test_handler_path_allocates_nothing() {
	raw := 'POST /baseline11?a=1%33&b=42 HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\n20'.bytes()
	mut f := Frame{}
	n := frame(raw, mut f, Limits{})!
	mut c := Ctx.new()
	c.out = []u8{cap: 4096}
	for h in [Handler(baseline_handler), Handler(json_handler)] {
		c.chain = [h]
		for _ in 0 .. 100 {
			serve_once(mut c, raw, f, n)
		}
		before := allocated_bytes()
		for _ in 0 .. 10000 {
			serve_once(mut c, raw, f, n)
		}
		assert allocated_bytes() - before == 0
	}
	assert c.out.bytestr().ends_with('{"message":"Hello, World!"}')
}

// A seventeenth response header is dropped, not a panic: a panic would take the
// process down, and recover cannot catch it.
fn test_seventeenth_header_is_dropped() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	for i in 0 .. 17 {
		c.set_header('X-N${i}', 'v')
	}
	c.text(200, 'ok')
	out := out_of(c)
	assert out.contains('X-N15: v\r\n')
	assert !out.contains('X-N16')
}

// Content-Range of a file past 10 GB has three numbers of up to 20 digits: the
// buffer it is written in holds the widest one.
fn test_content_range_of_a_huge_file() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	size := i64(18446744073709551) // 17 digits, each number
	s := c.content_range(size - 2, size - 1, size)
	assert s == 'bytes 18446744073709549-18446744073709550/18446744073709551'
	assert c.content_range(-1, 0, size) == 'bytes */18446744073709551'
	assert c.crange.len >= 24 + 6 + 20 + 1 + 20 + 1 + 20
}
