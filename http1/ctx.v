module http1

import viltrum.jsonenc

pub type Handler = fn (mut c Ctx)

// Resume writes a deferred response; see Ctx.after.
pub type Resume = fn (mut c Ctx, arg u64)

pub const ct_text = 'text/plain; charset=utf-8'
pub const ct_json = 'application/json'

struct HeaderPair {
	name  string
	value string
}

// Ctx is one request and its response. A worker owns a single Ctx and reuses it
// for every request, so nothing in here is allocated per request.
//
// Every string or slice a Ctx returns about the request points into connection
// buffers and is valid only until the handler returns. Clone it to keep it.
pub struct Ctx {
pub mut:
	// request
	buf         []u8 // the whole message
	head        Head
	body_bytes  []u8
	param_names []string
	params      [8]Span // absolute offsets into buf
	nparams     int
	// response
	status      int // 0 until a response is written
	close_after bool
	responded   bool
	capture     bool // gzip and other body-rewriting middleware set this around next()
	cap_type    string
	wrote       bool // the response went straight to out, past capture (file answers)
	// a file answer's body, streamed by the engine after the head: fd, offset, bytes
	file_fd   int = -1
	file_off  i64
	file_left i64
	// deferred response (after): the engine reads these once the chain returns
	deferred  bool
	defer_ms  int
	defer_cb  Resume = unsafe { nil }
	defer_arg u64
	// WebSocket upgrade (ws_upgrade): the engine takes the connection over after a 101
	ws       &WsHandler = unsafe { nil }
	ws_proto int
	// chain
	chain []Handler
	idx   int
	// per worker
	worker    int
	out       []u8 // the connection's write buffer, lent for one batch
	send_date bool = true
	server    string
	date      DateCache
	deflater  &Deflater = unsafe { nil } // set by the worker; gzip passes through while nil
mut:
	extra  [16]HeaderPair
	nextra int
	qbuf   []u8   // percent-decoded query values
	cbuf   []u8   // decoded chunked bodies
	jbuf   []u8   // JSON bodies and captured bodies
	ws_acc [28]u8 // Sec-WebSocket-Accept until the 101 is written
	// file answers: the path being opened, and header values until they are written
	pbuf    []u8
	etag    [56]u8
	lastmod [29]u8
	crange  [64]u8
}

pub fn Ctx.new() Ctx {
	return Ctx{
		qbuf: []u8{cap: 2048}
		cbuf: []u8{cap: 8 * 1024}
		jbuf: []u8{cap: 16 * 1024}
		pbuf: []u8{cap: 512}
	}
}

// begin resets per-request state for msg; c.head must already hold its parsed head.
pub fn (mut c Ctx) begin(msg []u8) {
	c.buf = msg
	c.body_bytes = view(msg, 0, 0)
	c.nparams = 0
	c.status = 0
	c.responded = false
	c.deferred = false
	c.ws = unsafe { nil }
	c.capture = false
	c.wrote = false
	c.file_fd = -1
	c.close_after = !c.head.keep_alive
	c.idx = 0
	c.nextra = 0
	unsafe {
		c.qbuf.len = 0
		c.jbuf.len = 0
	}
}

pub fn (mut c Ctx) set_body(b []u8) {
	c.body_bytes = b
}

// set_chunked_body decodes the chunked body that starts at buf[start].
pub fn (mut c Ctx) set_chunked_body(start int) {
	unsafe {
		c.cbuf.len = 0
	}
	decode_chunked(c.buf, start, mut c.cbuf)
	c.body_bytes = view(c.cbuf, 0, c.cbuf.len)
}

// --- request ---

pub fn (c &Ctx) method() Method {
	return c.head.method
}

pub fn (c &Ctx) path() string {
	if c.head.path.len == 0 {
		return '/'
	}
	return str_view(c.buf, c.head.path.start, c.head.path.len)
}

pub fn (c &Ctx) query() string {
	return str_view(c.buf, c.head.query.start, c.head.query.len)
}

// header returns the first request field named name (any case).
pub fn (c &Ctx) header(name string) ?string {
	for k in 0 .. c.head.nfields {
		f := c.head.fields[k]
		if eq_ci_span(c.buf, f.name, name) {
			return str_view(c.buf, f.value.start, f.value.len)
		}
	}
	return none
}

pub struct HeaderValues {
	c    &Ctx
	name string
mut:
	i int
}

// header_values iterates every request field named name (repeated fields are not joined).
pub fn (c &Ctx) header_values(name string) HeaderValues {
	return HeaderValues{
		c:    unsafe { c }
		name: name
	}
}

pub fn (mut it HeaderValues) next() ?string {
	for it.i < it.c.head.nfields {
		f := it.c.head.fields[it.i]
		it.i++
		if eq_ci_span(it.c.buf, f.name, it.name) {
			return str_view(it.c.buf, f.value.start, f.value.len)
		}
	}
	return none
}

pub fn (c &Ctx) param(name string) ?string {
	for k in 0 .. c.nparams {
		if c.param_names[k] == name {
			s := c.params[k]
			return str_view(c.buf, s.start, s.len)
		}
	}
	return none
}

pub fn (c &Ctx) param_int(name string) ?i64 {
	return parse_i64(c.param(name)?)
}

// query_param returns the first value of name in the query string with %XX and '+'
// decoded. A value without escapes is a view into the request; a decoded one lives
// in a per-request buffer. Both are valid until the handler returns.
pub fn (mut c Ctx) query_param(name string) ?string {
	end := c.head.query.start + c.head.query.len
	mut i := c.head.query.start
	for i < end {
		ks := i
		for i < end && c.buf[i] != `&` && c.buf[i] != `=` {
			i++
		}
		ke := i
		mut vs := i
		mut ve := i
		if i < end && c.buf[i] == `=` {
			i++
			vs = i
			for i < end && c.buf[i] != `&` {
				i++
			}
			ve = i
		}
		if i < end {
			i++
		}
		if ke > ks && c.key_is(ks, ke, name) {
			return c.decoded(vs, ve)
		}
	}
	return none
}

pub fn (mut c Ctx) query_int(name string) ?i64 {
	return parse_i64(c.query_param(name)?)
}

pub fn (c &Ctx) body() []u8 {
	return c.body_bytes
}

pub fn (c &Ctx) body_int() ?i64 {
	b := c.body_bytes
	if b.len == 0 {
		return none
	}
	return parse_i64(unsafe { tos(&u8(b.data), b.len) })
}

// worker_id is the index of the worker serving this request (0 .. workers-1), for
// per-worker state that must not be shared between threads.
pub fn (c &Ctx) worker_id() int {
	return c.worker
}

fn (mut c Ctx) key_is(s int, e int, name string) bool {
	if !needs_decode(c.buf, s, e) {
		return str_view(c.buf, s, e - s) == name
	}
	mark := c.qbuf.len
	ok := c.decoded(s, e) == name
	unsafe {
		c.qbuf.len = mark
	}
	return ok
}

fn needs_decode(buf []u8, s int, e int) bool {
	for k in s .. e {
		if buf[k] == `%` || buf[k] == `+` {
			return true
		}
	}
	return false
}

fn (mut c Ctx) decoded(s int, e int) string {
	if !needs_decode(c.buf, s, e) {
		return str_view(c.buf, s, e - s)
	}
	start := c.qbuf.len
	mut k := s
	for k < e {
		ch := c.buf[k]
		if ch == `+` {
			c.qbuf << ` `
			k++
			continue
		}
		if ch == `%` && k + 2 < e {
			hi := hex_value(c.buf[k + 1])
			lo := hex_value(c.buf[k + 2])
			if hi >= 0 && lo >= 0 {
				c.qbuf << u8(hi * 16 + lo)
				k += 3
				continue
			}
		}
		c.qbuf << ch
		k++
	}
	return str_view(c.qbuf, start, c.qbuf.len - start)
}

// begin_resumed resets the Ctx for a response written after its request is gone
// (see after). Only the request's method, version and keep-alive survive.
pub fn (mut c Ctx) begin_resumed(method Method, minor int, keep_alive bool) {
	c.head.method = method
	c.head.minor = minor
	c.head.keep_alive = keep_alive
	c.head.method_raw = Span{}
	c.head.target = Span{}
	c.head.path = Span{}
	c.head.query = Span{}
	c.head.nfields = 0
	c.begin(view(c.buf, 0, 0))
}

// --- chain ---

// next runs the rest of the chain. Middleware calls it; the final handler does not.
pub fn (mut c Ctx) next() {
	c.idx++
	if c.idx < c.chain.len {
		c.chain[c.idx](mut c)
	}
}

// --- response ---

// after answers this request later without holding the worker: the handler returns
// at once, and no sooner than ms milliseconds on, cb(mut c, arg) runs on the same
// worker to write the response (it may call after again). By then the request is
// gone: path, params, headers and body read empty, and headers set before after
// are dropped, so pass what cb needs in arg. Requests pipelined behind this one
// wait their turn. Middleware that runs after next() sees no response yet, so a
// deferred response is not gzipped. ms <= 0 calls cb right away.
pub fn (mut c Ctx) after(ms int, cb Resume, arg u64) {
	if c.responded || c.deferred {
		$if viltrum_debug ? {
			panic('viltrum: after() on a request that already has a response')
		}
		return
	}
	if ms <= 0 {
		cb(mut c, arg)
		return
	}
	c.deferred = true
	c.defer_ms = ms
	c.defer_cb = cb
	c.defer_arg = arg
}

// close asks the engine to close the connection after this response. Call it
// before writing the response so the Connection header says so.
pub fn (mut c Ctx) close() {
	c.close_after = true
}

// set_header adds a response header. At most 16; the strings must stay valid until
// the response is written (literals and request views are fine). A header whose name
// is not a token or whose value holds CR, LF or NUL is dropped, never written.
pub fn (mut c Ctx) set_header(name string, value string) {
	if !valid_name(name) || !valid_value(value) {
		return
	}
	if c.nextra == c.extra.len {
		panic('viltrum: more than 16 response headers')
	}
	c.extra[c.nextra] = HeaderPair{
		name:  name
		value: value
	}
	c.nextra++
}

fn valid_name(name string) bool {
	if name.len == 0 {
		return false
	}
	for k in 0 .. name.len {
		if !is_tchar(name[k]) {
			return false
		}
	}
	return true
}

fn valid_value(v string) bool {
	for k in 0 .. v.len {
		b := v[k]
		if b == `\r` || b == `\n` || b == 0 {
			return false
		}
	}
	return true
}

pub fn (c &Ctx) has_header(name string) bool {
	for k in 0 .. c.nextra {
		if eq_fold(c.extra[k].name, name) {
			return true
		}
	}
	return false
}

// eq_fold compares two strings ignoring ASCII case on both sides.
fn eq_fold(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	for k in 0 .. a.len {
		if lower(a[k]) != lower(b[k]) {
			return false
		}
	}
	return true
}

pub fn (mut c Ctx) text(status int, s string) {
	c.respond(status, ct_text, s.str, s.len)
}

pub fn (mut c Ctx) text_int(status int, n i64) {
	unsafe {
		c.jbuf.len = 0
	}
	append_int(mut c.jbuf, n)
	c.respond(status, ct_text, c.jbuf.data, c.jbuf.len)
}

pub fn (mut c Ctx) json[T](status int, val T) {
	unsafe {
		c.jbuf.len = 0
	}
	// `_ =` keeps V from pinning val around these calls (see jsonenc.encode_into)
	_ = jsonenc.encode_into(mut c.jbuf, val)
	_ = c.respond(status, ct_json, c.jbuf.data, c.jbuf.len)
}

pub fn (mut c Ctx) bytes(status int, content_type string, data []u8) {
	c.respond(status, content_type, data.data, data.len)
}

pub fn (mut c Ctx) no_content(status int) {
	c.respond(status, '', unsafe { nil }, 0)
}

// captured_body is what a handler wrote while capture was on.
pub fn (c &Ctx) captured_body() []u8 {
	return view(c.jbuf, 0, c.jbuf.len)
}

// send_captured writes the captured response with body, which may be a re-encoding
// of captured_body (content_encoding names it, '' for none).
pub fn (mut c Ctx) send_captured(body []u8, content_encoding string) {
	c.write_response(c.status, c.cap_type, content_encoding, body.data, body.len)
}

// respond returns false when a response was already sent.
fn (mut c Ctx) respond(status int, content_type string, body voidptr, n int) bool {
	if c.responded {
		$if viltrum_debug ? {
			panic('viltrum: second response for one request')
		}
		return false
	}
	c.responded = true
	c.status = status
	if c.capture {
		c.cap_type = content_type
		if body != c.jbuf.data {
			unsafe {
				c.jbuf.len = 0
				c.jbuf.push_many(body, n)
			}
		}
		return true
	}
	c.write_response(status, content_type, '', body, n)
	return true
}

fn (mut c Ctx) write_response(status int, content_type string, content_encoding string, body voidptr, n int) {
	if !c.write_response_fast(status, content_type, content_encoding, body, n) {
		c.write_response_slow(status, content_type, content_encoding, body, n)
	}
}

// write_response_slow is the piece-by-piece writer, for what the fast one declines.
fn (mut c Ctx) write_response_slow(status int, content_type string, content_encoding string, body voidptr, n int) {
	length := if body_allowed(status) { i64(n) } else { i64(-1) }
	c.write_head(status, content_type, content_encoding, length)
	if n > 0 && body_allowed(status) && c.head.method != .head {
		unsafe { c.out.push_many(body, n) }
	}
}

// write_head writes the status line and headers; length < 0 leaves Content-Length out.
fn (mut c Ctx) write_head(status int, content_type string, content_encoding string, length i64) {
	write_status_line(mut c.out, status)
	if content_type.len > 0 {
		write_header(mut c.out, 'Content-Type', if valid_value(content_type) {
			content_type
		} else {
			'application/octet-stream'
		})
	}
	if content_encoding.len > 0 {
		write_header(mut c.out, 'Content-Encoding', content_encoding)
	}
	if length >= 0 {
		append_str(mut c.out, 'Content-Length: ')
		append_int(mut c.out, length)
		append_str(mut c.out, crlf)
	}
	for k in 0 .. c.nextra {
		write_header(mut c.out, c.extra[k].name, c.extra[k].value)
	}
	if c.send_date {
		c.date.write(mut c.out)
	}
	if c.server.len > 0 {
		write_header(mut c.out, 'Server', c.server)
	}
	if c.close_after {
		append_str(mut c.out, 'Connection: close\r\n')
	} else if c.head.minor == 0 {
		append_str(mut c.out, 'Connection: keep-alive\r\n')
	}
	append_str(mut c.out, crlf)
}

// write_response_fast writes what write_response does with one capacity check and
// plain copies; a push per piece was about 20 calls per response. It declines (false)
// when out lacks room or is a slice, or the status is not three digits.
@[direct_array_access]
fn (mut c Ctx) write_response_fast(status int, content_type string, content_encoding string, body voidptr, n int) bool {
	if status < 100 || status > 999 || c.out.flags.has(.is_slice) {
		return false
	}
	ct := if content_type.len == 0 || valid_value(content_type) {
		content_type
	} else {
		'application/octet-stream'
	}
	rs := reason(status)
	with_length := body_allowed(status)
	with_body := n > 0 && with_length && c.head.method != .head
	// every fixed piece below, counted generously
	mut need := 160 + rs.len + ct.len + content_encoding.len + c.server.len
	for k in 0 .. c.nextra {
		need += c.extra[k].name.len + c.extra[k].value.len + 4
	}
	if with_body {
		need += n
	}
	if c.out.len + need > c.out.cap {
		return false
	}
	unsafe {
		mut p := &u8(c.out.data) + c.out.len
		p = put_str(p, 'HTTP/1.1 ')
		p[0] = u8(`0` + status / 100)
		p[1] = u8(`0` + status / 10 % 10)
		p[2] = u8(`0` + status % 10)
		p[3] = ` `
		p = put_str(p + 4, rs)
		p = put_str(p, crlf)
		if ct.len > 0 {
			p = put_str(p, 'Content-Type: ')
			p = put_str(p, ct)
			p = put_str(p, crlf)
		}
		if content_encoding.len > 0 {
			p = put_str(p, 'Content-Encoding: ')
			p = put_str(p, content_encoding)
			p = put_str(p, crlf)
		}
		if with_length {
			p = put_str(p, 'Content-Length: ')
			p = put_uint(p, u64(n))
			p = put_str(p, crlf)
		}
		for k in 0 .. c.nextra {
			p = put_str(p, c.extra[k].name)
			p = put_str(p, ': ')
			p = put_str(p, c.extra[k].value)
			p = put_str(p, crlf)
		}
		if c.send_date {
			p = put_str(p, 'Date: ')
			C.memcpy(p, c.date.text_now(), 29)
			p = put_str(p + 29, crlf)
		}
		if c.server.len > 0 {
			p = put_str(p, 'Server: ')
			p = put_str(p, c.server)
			p = put_str(p, crlf)
		}
		if c.close_after {
			p = put_str(p, 'Connection: close\r\n')
		} else if c.head.minor == 0 {
			p = put_str(p, 'Connection: keep-alive\r\n')
		}
		p = put_str(p, crlf)
		if with_body {
			C.memcpy(p, body, n)
			p += n
		}
		c.out.len = int(p - &u8(c.out.data))
	}
	return true
}

// put_str copies s to p and returns the byte after it.
@[inline; unsafe]
fn put_str(p &u8, s string) &u8 {
	unsafe {
		C.memcpy(p, s.str, s.len)
		return p + s.len
	}
}

// put_uint writes n in decimal at p and returns the byte after it.
@[inline; unsafe]
fn put_uint(p &u8, n u64) &u8 {
	mut tmp := [20]u8{}
	mut i := 20
	mut v := n
	for {
		i--
		tmp[i] = u8(`0` + v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	unsafe {
		C.memcpy(p, &tmp[i], 20 - i)
		return p + (20 - i)
	}
}
