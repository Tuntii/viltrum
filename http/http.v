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
	h.values[name.to_lower()] = value
}

// add appends with comma if the header already exists (RFC 7230 combine).
pub fn (mut h HeaderMap) add(name string, value string) {
	key := name.to_lower()
	if key in h.values {
		h.values[key] = h.values[key] + ', ' + value
	} else {
		h.values[key] = value
	}
}

pub fn (h &HeaderMap) get(name string) ?string {
	key := name.to_lower()
	if key in h.values {
		return h.values[key]
	}
	return none
}

pub fn (h &HeaderMap) get_or(name string, default_value string) string {
	return h.get(name) or { default_value }
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

// json_int extracts a top-level JSON number field ("key":123).
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

// json_bool extracts true/false.
pub fn (r &Request) json_bool(key string) ?bool {
	s := json_extract_raw(r.text(), key) or { return none }
	return match s {
		'true' { true }
		'false' { false }
		else { none }
	}
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
	r.headers.set('Content-Type', 'text/plain; charset=utf-8')
	r.headers.set('Content-Length', '${r.body.len}')
	r.headers.set('Connection', 'keep-alive')
	return r
}

pub fn Response.json(status int, body string) Response {
	mut r := Response{
		status:  status
		reason:  status_text(status)
		headers: HeaderMap.new()
		body:    body.bytes()
	}
	r.headers.set('Content-Type', 'application/json; charset=utf-8')
	r.headers.set('Content-Length', '${r.body.len}')
	r.headers.set('Connection', 'keep-alive')
	return r
}

pub fn Response.empty(status int) Response {
	mut r := Response{
		status:  status
		reason:  status_text(status)
		headers: HeaderMap.new()
		body:    []u8{}
	}
	r.headers.set('Content-Length', '0')
	r.headers.set('Connection', 'keep-alive')
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
	r.headers.set('Connection', 'Upgrade')
	if upgrade_proto.len > 0 {
		r.headers.set('Upgrade', upgrade_proto)
	}
	return r
}

pub fn (mut r Response) header(name string, value string) Response {
	r.headers.set(name, value)
	return r
}

pub fn (mut r Response) set_connection_close() {
	r.headers.set('Connection', 'close')
}

pub fn (r &Response) to_bytes() []u8 {
	return r.to_bytes_for_method('')
}

// to_bytes_for_method serializes the response. For HEAD, headers are kept (including
// Content-Length) but the body octets are omitted (RFC 9110 §9.3.2).
pub fn (r &Response) to_bytes_for_method(method string) []u8 {
	mut out := 'HTTP/1.1 ${r.status} ${r.reason}\r\n'
	for k, v in r.headers.values {
		out += '${canonicalize_header_name(k)}: ${v}\r\n'
	}
	out += '\r\n'
	mut bytes := out.bytes()
	if r.body.len > 0 && method.to_upper() != 'HEAD' {
		bytes << r.body
	}
	return bytes
}

pub fn should_close(req Request, resp Response) bool {
	resp_conn := resp.headers.get_or('connection', '').to_lower()
	if resp_conn == 'close' {
		return true
	}
	req_conn := req.headers.get_or('connection', '').to_lower()
	if req_conn == 'close' {
		return true
	}
	if req.version.starts_with('HTTP/1.0') {
		return req_conn != 'keep-alive'
	}
	return false
}

pub fn parse_request(raw []u8) !Request {
	text := raw.bytestr()
	sep := text.index('\r\n\r\n') or { return error('incomplete headers') }
	head := text[..sep]
	body_start := sep + 4
	lines := head.split('\r\n')
	if lines.len == 0 || lines[0].len == 0 {
		return error('empty request')
	}
	// reject bare LF request lines (require CRLF framing already split)
	parts := lines[0].split(' ')
	if parts.len != 3 {
		return error('bad request line')
	}
	method := parts[0]
	if method.len == 0 {
		return error('empty method')
	}
	target := parts[1]
	version := parts[2]
	if !version.starts_with('HTTP/') {
		return error('bad version')
	}
	path_raw, query := split_target(target)
	// OPTIONS * keeps asterisk path; absolute-form is reduced in split_target
	path := if path_raw == '*' { '*' } else { normalize_path(path_raw) }

	mut headers := HeaderMap.new()
	for i in 1 .. lines.len {
		line := lines[i]
		if line.len == 0 {
			continue
		}
		colon := line.index(':') or { return error('bad header line') }
		name := line[..colon].trim_space()
		if name.len == 0 {
			return error('empty header name')
		}
		value := line[colon + 1..].trim_space()
		headers.add(name, value)
	}

	// TE + Content-Length together is invalid (RFC 9112). TE alone (e.g. chunked) is unsupported.
	te := headers.get('transfer-encoding') or { '' }
	cl_hdr := headers.get('content-length') or { '' }
	if te.len > 0 && cl_hdr.len > 0 {
		return error('transfer-encoding and content-length conflict')
	}
	if te.len > 0 {
		return error('transfer-encoding not supported')
	}

	mut body := []u8{}
	if cl := headers.get('content-length') {
		n := cl.int()
		if n < 0 {
			return error('negative content-length')
		}
		available := raw.len - body_start
		if available < n {
			return error('incomplete body')
		}
		if n > 0 {
			body = raw[body_start..body_start + n].clone()
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
