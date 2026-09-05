module http

// HTTP/1.1 types + parse/serialize for Viltrum.

import time

pub struct HeaderMap {
mut:
	values map[string]string
}

pub fn HeaderMap.new() HeaderMap {
	return HeaderMap{
		values: map[string]string{}
	}
}

pub fn (mut h HeaderMap) set(name string, value string) {
	h.set_lowered(name.to_lower(), value)
}

// set_lowered stores under a key that is already lowercased (no to_lower).
// Hot path for known headers and parse results.
pub fn (mut h HeaderMap) set_lowered(key string, value string) {
	h.values[key] = value
}

// add appends with comma if the header already exists (RFC 7230 combine).
pub fn (mut h HeaderMap) add(name string, value string) {
	h.add_lowered(name.to_lower(), value)
}

// add_lowered is add for an already-lowercased key.
pub fn (mut h HeaderMap) add_lowered(key string, value string) {
	if key in h.values {
		h.values[key] = h.values[key] + ', ' + value
	} else {
		h.values[key] = value
	}
}

pub fn (h &HeaderMap) get(name string) ?string {
	return h.get_lowered(name.to_lower())
}

// get_lowered looks up a key that is already lowercased (no to_lower alloc).
pub fn (h &HeaderMap) get_lowered(key string) ?string {
	if key in h.values {
		return h.values[key]
	}
	return none
}

pub fn (h &HeaderMap) get_or(name string, default_value string) string {
	return h.get(name) or { default_value }
}

pub fn (h &HeaderMap) get_or_lowered(key string, default_value string) string {
	return h.get_lowered(key) or { default_value }
}

pub struct Request {
pub:
	method  string
	target  string
	path    string
	query   string
	version string
	headers HeaderMap
	body    []u8
pub mut:
	params map[string]string
	ctx    voidptr
}

pub fn (r &Request) param(name string) ?string {
	if name in r.params {
		return r.params[name]
	}
	return none
}

pub fn (r &Request) query_param(name string) ?string {
	if r.query.len == 0 {
		return none
	}
	for part in r.query.split('&') {
		if part.len == 0 {
			continue
		}
		eq := part.index('=') or {
			k := url_decode(part) or { part }
			if k == name {
				return ''
			}
			continue
		}
		k := url_decode(part[..eq]) or { part[..eq] }
		if k == name {
			return url_decode(part[eq + 1..]) or { part[eq + 1..] }
		}
	}
	return none
}

pub fn (r &Request) text() string {
	return r.body.bytestr()
}

// json_string extracts a top-level JSON string field ("key":"value"). Minimal, not a full parser.
pub fn (r &Request) json_string(key string) ?string {
	return json_extract_string(r.text(), key)
}

// json_int extracts a top-level JSON number field ("key":123) as platform int.
pub fn (r &Request) json_int(key string) ?int {
	s := json_extract_raw(r.text(), key) or { return none }
	if s.len == 0 {
		return none
	}
	// reject quoted strings for int path
	if s.starts_with('"') {
		return none
	}
	return s.int()
}

// json_i64 extracts a top-level JSON number as i64 (IDs that overflow int).
pub fn (r &Request) json_i64(key string) ?i64 {
	s := json_extract_raw(r.text(), key) or { return none }
	if s.len == 0 || s.starts_with('"') {
		return none
	}
	return s.i64()
}

// json_bool extracts true/false.
pub fn (r &Request) json_bool(key string) ?bool {
	s := json_extract_raw(r.text(), key) or { return none }
	return match s {
		'true' { true }
		'false' { false }
		else { none }
	}
}

// json_float extracts a top-level JSON number as f64.
pub fn (r &Request) json_float(key string) ?f64 {
	s := json_extract_raw(r.text(), key) or { return none }
	if s.len == 0 || s.starts_with('"') {
		return none
	}
	return s.f64()
}

// json_raw returns the raw top-level value text: quoted string contents with
// quotes, or number/bool/null token, or a `{...}` / `[...]` slice.
pub fn (r &Request) json_raw(key string) ?string {
	return json_extract_value(r.text(), key)
}

// json_is_null is true when the top-level field is JSON null.
pub fn (r &Request) json_is_null(key string) bool {
	s := json_extract_raw(r.text(), key) or { return false }
	return s == 'null'
}

// json_strings extracts a top-level JSON array of strings ("key":["a","b"]).
pub fn (r &Request) json_strings(key string) ?[]string {
	raw := json_extract_value(r.text(), key) or { return none }
	if !raw.starts_with('[') {
		return none
	}
	return json_parse_string_array(raw)
}

// json_escape escapes a string for embedding in a JSON string literal.
// ASCII controls other than \n \r \t become \u00XX. Not a full JSON encoder.
pub fn json_escape(s string) string {
	mut out := ''
	for i in 0 .. s.len {
		c := s[i]
		out += match c {
			`\\` { '\\\\' }
			`"` { '\\"' }
			`\n` { '\\n' }
			`\r` { '\\r' }
			`\t` { '\\t' }
			else {
				if c < 0x20 {
					json_u00(c)
				} else {
					c.ascii_str()
				}
			}
		}
	}
	return out
}

fn json_u00(c u8) string {
	hex := '0123456789abcdef'
	return '\\u00${hex[c >> 4].ascii_str()}${hex[c & 0xf].ascii_str()}'
}

pub struct Response {
pub mut:
	status  int
	reason  string
	headers HeaderMap
	body    []u8
}

pub fn Response.text(status int, body string) Response {
	mut r := Response{
		status:  status
		reason:  status_text(status)
		headers: HeaderMap.new()
		body:    body.bytes()
	}
	// Keys already lower — avoid to_lower on every default response.
	r.headers.set_lowered('content-type', 'text/plain; charset=utf-8')
	r.headers.set_lowered('content-length', '${r.body.len}')
	r.headers.set_lowered('connection', 'keep-alive')
	return r
}

pub fn Response.json(status int, body string) Response {
	mut r := Response{
		status:  status
		reason:  status_text(status)
		headers: HeaderMap.new()
		body:    body.bytes()
	}
	r.headers.set_lowered('content-type', 'application/json; charset=utf-8')
	r.headers.set_lowered('content-length', '${r.body.len}')
	r.headers.set_lowered('connection', 'keep-alive')
	return r
}

pub fn Response.empty(status int) Response {
	mut r := Response{
		status:  status
		reason:  status_text(status)
		headers: HeaderMap.new()
		body:    []u8{}
	}
	r.headers.set_lowered('content-length', '0')
	r.headers.set_lowered('connection', 'keep-alive')
	return r
}

pub fn Response.not_found() Response {
	return Response.text(404, 'not found')
}

pub fn Response.method_not_allowed() Response {
	return Response.text(405, 'method not allowed')
}

pub fn Response.bad_request(msg string) Response {
	return Response.text(400, msg)
}

// switching_protocols builds a bare 101 response (no Content-Length).
// Used by upgrade handlers before taking over the byte stream.
pub fn Response.switching_protocols(upgrade_proto string) Response {
	mut r := Response{
		status:  101
		reason:  'Switching Protocols'
		headers: HeaderMap.new()
		body:    []u8{}
	}
	r.headers.set_lowered('connection', 'Upgrade')
	if upgrade_proto.len > 0 {
		r.headers.set_lowered('upgrade', upgrade_proto)
	}
	return r
}

pub fn (mut r Response) header(name string, value string) Response {
	r.headers.set(name, value)
	return r
}

pub fn (mut r Response) set_connection_close() {
	r.headers.set_lowered('connection', 'close')
}

pub fn (r &Response) to_bytes() []u8 {
	return r.to_bytes_for_method('')
}

// to_bytes_for_method serializes the response into a single pre-sized []u8 buffer.
// For HEAD, headers are kept (including Content-Length) but the body octets are
// omitted (RFC 9110 §9.3.2). Header names use a known-header casing cache so the
// hot path avoids per-field split/join canonicalize; unknown names still fold.
pub fn (r &Response) to_bytes_for_method(method string) []u8 {
	mut out := []u8{}
	r.to_bytes_for_method_into(mut out, method)
	return out
}

// to_bytes_for_method_into serializes into `out`, reusing capacity when possible
// (conn-local write scratch on the keep-alive path). Wire format matches
// to_bytes_for_method. After return, `out.len` is the exact wire size.
pub fn (r &Response) to_bytes_for_method_into(mut out []u8, method string) {
	include_body := r.body.len > 0 && !is_head_method(method)

	// Capacity: status line + each "Name: value\r\n" + final CRLF + optional body.
	mut need := 16 + r.reason.len // "HTTP/1.1 NNN " + reason + CRLF (status ≤ 3–4 digits)
	for k, v in r.headers.values {
		// Wire name ≤ slightly larger than lowercased key; +4 for ": \r\n"
		need += k.len + 8 + v.len + 4
	}
	need += 2
	if include_body {
		need += r.body.len
	}

	if out.cap < need {
		out = []u8{cap: need}
	} else {
		unsafe {
			out.len = 0
		}
	}

	append_str(mut out, 'HTTP/1.1 ')
	append_status_code(mut out, r.status)
	out << ` `
	append_str(mut out, r.reason)
	out << `\r`
	out << `\n`

	for k, v in r.headers.values {
		append_wire_header_name(mut out, k)
		out << `:`
		out << ` `
		append_str(mut out, v)
		out << `\r`
		out << `\n`
	}
	out << `\r`
	out << `\n`
	if include_body {
		out << r.body
	}
}

pub fn should_close(req Request, resp Response) bool {
	// Values compared case-insensitively without allocating to_lower strings.
	resp_conn := resp.headers.get_or_lowered('connection', '')
	if eq_ascii_ci(resp_conn, 'close') {
		return true
	}
	req_conn := req.headers.get_or_lowered('connection', '')
	if eq_ascii_ci(req_conn, 'close') {
		return true
	}
	if req.version.starts_with('HTTP/1.0') {
		return !eq_ascii_ci(req_conn, 'keep-alive')
	}
	return false
}

// eq_ascii_ci is true when s matches lower (ASCII lowercased literal) ignoring case.
fn eq_ascii_ci(s string, lower string) bool {
	if s.len != lower.len {
		return false
	}
	for i in 0 .. s.len {
		mut c := s[i]
		if c >= `A` && c <= `Z` {
			c += 32
		}
		if c != lower[i] {
			return false
		}
	}
	return true
}

// parse_request walks request-line + header fields on raw bytes. It does not
// string-convert the full message. Body octets are a slice of `raw` (no second
// materialization): engine `finish_message` already owns the message buffer, so
// Request.body shares that storage instead of cloning the body again.
pub fn parse_request(raw []u8) !Request {
	sep := index_of_double_crlf(raw) or { return error('incomplete headers') }
	body_start := sep + 4

	mut method := ''
	mut target := ''
	mut version := ''
	mut headers := HeaderMap.new()
	mut line_idx := 0
	mut i := 0
	for i <= sep {
		line_end := find_crlf_or(raw, i, sep)
		line := raw[i..line_end]

		if line_idx == 0 {
			if line.len == 0 {
				return error('empty request')
			}
			method, target, version = parse_request_line(line)!
		} else if line.len > 0 {
			colon := index_byte(line, `:`) or { return error('bad header line') }
			name := trim_ows(line[..colon])
			if name.len == 0 {
				return error('empty header name')
			}
			value := trim_ows(line[colon + 1..])
			// Lowercase field name while materializing; value kept as wire octets → string.
			headers.add_lowered(bytes_to_lower_str(name), value.bytestr())
		}

		line_idx++
		if line_end >= sep {
			break
		}
		i = line_end + 2 // skip CRLF
	}

	path_raw, query := split_target(target)
	// OPTIONS * keeps asterisk path; absolute-form is reduced in split_target
	path := if path_raw == '*' { '*' } else { normalize_path(path_raw) }

	// TE + Content-Length together is invalid (RFC 9112). TE alone (e.g. chunked) is unsupported.
	// Keys already lower in the map — no to_lower on lookup.
	te := headers.get_lowered('transfer-encoding') or { '' }
	cl_hdr := headers.get_lowered('content-length') or { '' }
	if te.len > 0 && cl_hdr.len > 0 {
		return error('transfer-encoding and content-length conflict')
	}
	if te.len > 0 {
		return error('transfer-encoding not supported')
	}

	mut body := []u8{}
	if cl_hdr.len > 0 {
		n := cl_hdr.int()
		if n < 0 {
			return error('negative content-length')
		}
		available := raw.len - body_start
		if available < n {
			return error('incomplete body')
		}
		if n > 0 {
			// View into message buffer (no copy). Safe while Request.body is live: V GC
			// keeps the underlying allocation; engine keeps `raw` for the request turn.
			// Explicit unsafe avoids V's default implicit slice clone.
			body = unsafe { raw[body_start..body_start + n] }
		}
	}

	return Request{
		method:  method
		target:  target
		path:    path
		query:   query
		version: version
		headers: headers
		body:    body
		params:  map[string]string{}
		ctx:     unsafe { nil }
	}
}

// parse_request_line requires exactly three SP-separated tokens (same as prior split).
fn parse_request_line(line []u8) !(string, string, string) {
	mut sp1 := -1
	mut sp2 := -1
	for k in 0 .. line.len {
		if line[k] != ` ` {
			continue
		}
		if sp1 < 0 {
			sp1 = k
		} else if sp2 < 0 {
			sp2 = k
		} else {
			return error('bad request line')
		}
	}
	if sp1 < 0 || sp2 < 0 {
		return error('bad request line')
	}
	if sp1 == 0 {
		return error('empty method')
	}
	method := line[..sp1].bytestr()
	target := line[sp1 + 1..sp2].bytestr()
	version := line[sp2 + 1..].bytestr()
	if !version.starts_with('HTTP/') {
		return error('bad version')
	}
	return method, target, version
}

// find_crlf_or returns the index of CRLF in raw[from..limit), or limit if none.
fn find_crlf_or(raw []u8, from int, limit int) int {
	mut j := from
	for j < limit {
		if raw[j] == `\r` && j + 1 < raw.len && raw[j + 1] == `\n` {
			return j
		}
		j++
	}
	return limit
}

fn index_of_double_crlf(buf []u8) ?int {
	if buf.len < 4 {
		return none
	}
	limit := buf.len - 3
	for i in 0 .. limit {
		if buf[i] == `\r` && buf[i + 1] == `\n` && buf[i + 2] == `\r` && buf[i + 3] == `\n` {
			return i
		}
	}
	return none
}

fn index_byte(buf []u8, b u8) ?int {
	for i in 0 .. buf.len {
		if buf[i] == b {
			return i
		}
	}
	return none
}

// trim_ows strips leading/trailing SP and HTAB (HTTP OWS).
fn trim_ows(buf []u8) []u8 {
	mut a := 0
	mut b := buf.len
	for a < b && (buf[a] == ` ` || buf[a] == `\t`) {
		a++
	}
	for b > a && (buf[b - 1] == ` ` || buf[b - 1] == `\t`) {
		b--
	}
	if a == 0 && b == buf.len {
		return buf
	}
	return buf[a..b]
}

// bytes_to_lower_str materializes buf as a string with ASCII A–Z folded to lower.
fn bytes_to_lower_str(buf []u8) string {
	mut out := []u8{len: buf.len}
	for i in 0 .. buf.len {
		c := buf[i]
		if c >= `A` && c <= `Z` {
			out[i] = c + 32
		} else {
			out[i] = c
		}
	}
	return out.bytestr()
}

// normalize_path collapses trailing slashes except for root "/".
pub fn normalize_path(path string) string {
	if path.len <= 1 {
		return if path.len == 0 { '/' } else { path }
	}
	return path.trim_right('/')
}

// split_target returns path and query. Absolute-form
// (http://host/path?q or https://...) is reduced to path + query.
// Asterisk-form (*) is returned as path "*" with empty query.
fn split_target(target string) (string, string) {
	if target == '*' {
		return '*', ''
	}
	mut t := target
	lower := t.to_lower()
	if lower.starts_with('http://') || lower.starts_with('https://') {
		// strip scheme://
		scheme_end := t.index('://') or { 0 }
		rest := t[scheme_end + 3..]
		// authority ends at first /
		slash := rest.index('/') or {
			// http://host or http://host?q → path /
			qonly := rest.index('?') or { return '/', '' }
			return '/', rest[qonly + 1..]
		}
		t = rest[slash..]
	}
	q := t.index('?') or { return t, '' }
	return t[..q], t[q + 1..]
}

// url_decode decodes percent-encoding and '+' → space (query form).
pub fn url_decode(s string) !string {
	mut out := []u8{cap: s.len}
	mut i := 0
	for i < s.len {
		c := s[i]
		if c == `+` {
			out << ` `
			i++
			continue
		}
		if c == `%` {
			if i + 2 >= s.len {
				return error('truncated escape')
			}
			hi := hex_nibble(s[i + 1]) or { return error('bad escape') }
			lo := hex_nibble(s[i + 2]) or { return error('bad escape') }
			out << u8((u8(hi) << 4) | u8(lo))
			i += 3
			continue
		}
		out << c
		i++
	}
	return out.bytestr()
}

fn hex_nibble(c u8) ?u8 {
	return match c {
		`0`...`9` { u8(c - `0`) }
		`a`...`f` { u8(c - `a` + 10) }
		`A`...`F` { u8(c - `A` + 10) }
		else { none }
	}
}

fn json_extract_string(raw string, key string) ?string {
	needle := '"${key}"'
	idx := raw.index(needle) or { return none }
	rest := raw[idx + needle.len..].trim_space()
	if !rest.starts_with(':') {
		return none
	}
	after := rest[1..].trim_space()
	if !after.starts_with('"') {
		return none
	}
	mut i := 1
	mut out := ''
	for i < after.len {
		c := after[i]
		if c == `\\` && i + 1 < after.len {
			out += after[i + 1].ascii_str()
			i += 2
			continue
		}
		if c == `"` {
			return out
		}
		out += c.ascii_str()
		i++
	}
	return none
}

// json_extract_value is json_extract_raw plus object/array slices.
fn json_extract_value(raw string, key string) ?string {
	needle := '"${key}"'
	idx := raw.index(needle) or { return none }
	rest := raw[idx + needle.len..].trim_space()
	if !rest.starts_with(':') {
		return none
	}
	after := rest[1..].trim_space()
	if after.len == 0 {
		return none
	}
	if after.starts_with('{') || after.starts_with('[') {
		return json_balanced_slice(after)
	}
	return json_extract_raw(raw, key)
}

fn json_balanced_slice(after string) ?string {
	open := after[0]
	close := if open == `{` { `}` } else { `]` }
	mut depth := 0
	mut in_str := false
	mut esc := false
	for i in 0 .. after.len {
		c := after[i]
		if in_str {
			if esc {
				esc = false
			} else if c == `\\` {
				esc = true
			} else if c == `"` {
				in_str = false
			}
			continue
		}
		if c == `"` {
			in_str = true
			continue
		}
		if c == open {
			depth++
		} else if c == close {
			depth--
			if depth == 0 {
				return after[..i + 1]
			}
		}
	}
	return none
}

fn json_parse_string_array(raw string) ?[]string {
	mut out := []string{}
	mut i := 1 // skip [
	for i < raw.len {
		for i < raw.len && raw[i] in [` `, `\t`, `\n`, `\r`, `,`] {
			i++
		}
		if i < raw.len && raw[i] == `]` {
			return out
		}
		if i >= raw.len || raw[i] != `"` {
			return none
		}
		// reuse string extractor on a fake object
		frag := '{"k":${raw[i..]}}'
		s := json_extract_string(frag, 'k') or { return none }
		out << s
		// advance past this string in raw
		i++ // opening quote
		for i < raw.len {
			if raw[i] == `\\` && i + 1 < raw.len {
				i += 2
				continue
			}
			if raw[i] == `"` {
				i++
				break
			}
			i++
		}
	}
	return none
}

fn json_extract_raw(raw string, key string) ?string {
	needle := '"${key}"'
	idx := raw.index(needle) or { return none }
	rest := raw[idx + needle.len..].trim_space()
	if !rest.starts_with(':') {
		return none
	}
	after := rest[1..].trim_space()
	if after.len == 0 {
		return none
	}
	if after.starts_with('"') {
		// return including quotes for int path rejection; string path uses json_extract_string
		s := json_extract_string(raw, key) or { return none }
		return '"${s}"'
	}
	// number, bool, null until delimiter
	mut i := 0
	for i < after.len {
		c := after[i]
		if c in [` `, `	`, `\n`, `\r`, `,`, `}`, `]`] {
			break
		}
		i++
	}
	if i == 0 {
		return none
	}
	return after[..i]
}

fn status_text(code int) string {
	return match code {
		100 { 'Continue' }
		101 { 'Switching Protocols' }
		200 { 'OK' }
		201 { 'Created' }
		204 { 'No Content' }
		400 { 'Bad Request' }
		404 { 'Not Found' }
		405 { 'Method Not Allowed' }
		411 { 'Length Required' }
		413 { 'Payload Too Large' }
		500 { 'Internal Server Error' }
		503 { 'Service Unavailable' }
		else { 'OK' }
	}
}

// http_date formats t as RFC 9110 IMF-fixdate (HTTP-date), always GMT.
// Pass time.utc() (or any UTC Time) for correct wire values.
pub fn http_date(t time.Time) string {
	// ddd, DD MMM YYYY HH:mm:ss GMT
	return t.custom_format('ddd, DD MMM YYYY HH:mm:ss') + ' GMT'
}

// is_head_method is true for "HEAD" (any ASCII case) without a full to_upper alloc.
fn is_head_method(method string) bool {
	if method.len != 4 {
		return false
	}
	// case-insensitive HEAD
	return (method[0] | 32) == `h` && (method[1] | 32) == `e` && (method[2] | 32) == `a` && (method[3] | 32) == `d`
}

fn append_str(mut buf []u8, s string) {
	for i in 0 .. s.len {
		buf << s[i]
	}
}

// append_status_code writes a decimal HTTP status (typically 100–599) without formatting.
fn append_status_code(mut buf []u8, code int) {
	if code >= 100 && code <= 999 {
		buf << u8(`0` + code / 100)
		buf << u8(`0` + (code / 10) % 10)
		buf << u8(`0` + code % 10)
		return
	}
	// Rare non-3-digit: fall back to decimal digits
	if code <= 0 {
		buf << `0`
		return
	}
	mut x := code
	mut tmp := []u8{cap: 10}
	for x > 0 {
		tmp << u8(`0` + (x % 10))
		x /= 10
	}
	for i := tmp.len - 1; i >= 0; i-- {
		buf << tmp[i]
	}
}

// append_wire_header_name writes the conventional Title-Case field name for a
// lowercased HeaderMap key. Hot-path names are a fixed match (no split/join).
fn append_wire_header_name(mut buf []u8, name string) {
	// Keys in HeaderMap are already lowercased by set/add.
	known := match name {
		'content-type' { 'Content-Type' }
		'content-length' { 'Content-Length' }
		'connection' { 'Connection' }
		'date' { 'Date' }
		'server' { 'Server' }
		'host' { 'Host' }
		'upgrade' { 'Upgrade' }
		'location' { 'Location' }
		'transfer-encoding' { 'Transfer-Encoding' }
		'content-encoding' { 'Content-Encoding' }
		'cache-control' { 'Cache-Control' }
		'set-cookie' { 'Set-Cookie' }
		'www-authenticate' { 'WWW-Authenticate' }
		'sec-websocket-accept' { 'Sec-WebSocket-Accept' }
		'sec-websocket-protocol' { 'Sec-WebSocket-Protocol' }
		'sec-websocket-version' { 'Sec-WebSocket-Version' }
		'sec-websocket-key' { 'Sec-WebSocket-Key' }
		else { '' }
	}
	if known.len > 0 {
		append_str(mut buf, known)
		return
	}
	append_str(mut buf, canonicalize_header_name(name))
}

// canonicalize_header_name Title-Cases a lowercased (or mixed) header token on '-'.
// Used for unknown custom headers on the wire.
fn canonicalize_header_name(name string) string {
	parts := name.split('-')
	mut out := []string{cap: parts.len}
	for p in parts {
		if p.len == 0 {
			continue
		}
		upper := p[0].ascii_str().to_upper()
		rest := if p.len > 1 { p[1..].to_lower() } else { '' }
		out << upper + rest
	}
	return out.join('-')
}
