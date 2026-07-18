module http

// HTTP/1.1 types + parse/serialize for Viltrum.

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
	// route :params (set by router)
	params map[string]string
	// app-level context pointer (optional)
	ctx voidptr
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
			if part == name {
				return ''
			}
			continue
		}
		k := part[..eq]
		if k == name {
			return part[eq + 1..]
		}
	}
	return none
}

pub fn (r &Request) text() string {
	return r.body.bytestr()
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

pub fn (mut r Response) set_connection_close() {
	r.headers.set('Connection', 'close')
}

pub fn (r &Response) to_bytes() []u8 {
	mut out := 'HTTP/1.1 ${r.status} ${r.reason}\r\n'
	for k, v in r.headers.values {
		out += '${canonicalize_header_name(k)}: ${v}\r\n'
	}
	out += '\r\n'
	mut bytes := out.bytes()
	if r.body.len > 0 {
		bytes << r.body
	}
	return bytes
}

// should_close decides if the TCP connection must drop after this response.
pub fn should_close(req Request, resp Response) bool {
	resp_conn := resp.headers.get_or('connection', '').to_lower()
	if resp_conn == 'close' {
		return true
	}
	req_conn := req.headers.get_or('connection', '').to_lower()
	if req_conn == 'close' {
		return true
	}
	// HTTP/1.0 defaults to close unless keep-alive requested
	if req.version.starts_with('HTTP/1.0') {
		return req_conn != 'keep-alive'
	}
	// HTTP/1.1+ default keep-alive
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
	parts := lines[0].split(' ')
	if parts.len < 3 {
		return error('bad request line')
	}
	method := parts[0]
	target := parts[1]
	version := parts[2]
	path, query := split_target(target)

	mut headers := HeaderMap.new()
	for i in 1 .. lines.len {
		line := lines[i]
		if line.len == 0 {
			continue
		}
		colon := line.index(':') or { return error('bad header line') }
		name := line[..colon].trim_space()
		value := line[colon + 1..].trim_space()
		headers.set(name, value)
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

fn split_target(target string) (string, string) {
	q := target.index('?') or { return target, '' }
	return target[..q], target[q + 1..]
}

fn status_text(code int) string {
	return match code {
		200 { 'OK' }
		201 { 'Created' }
		204 { 'No Content' }
		400 { 'Bad Request' }
		404 { 'Not Found' }
		405 { 'Method Not Allowed' }
		413 { 'Payload Too Large' }
		500 { 'Internal Server Error' }
		else { 'OK' }
	}
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
