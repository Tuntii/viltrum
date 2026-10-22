module http1

// Request head parser. It validates the head and records spans into the message
// buffer; nothing is copied. The rules are the v0.13 ones: a front proxy and we
// must never disagree about a request (smuggling), so ambiguity is refused.

pub enum Method {
	get
	head
	post
	put
	delete
	patch
	options
	connect
	trace
	other
}

pub fn method_of(s string) Method {
	return match s {
		'GET' { .get }
		'HEAD' { .head }
		'POST' { .post }
		'PUT' { .put }
		'DELETE' { .delete }
		'PATCH' { .patch }
		'OPTIONS' { .options }
		'CONNECT' { .connect }
		'TRACE' { .trace }
		else { .other }
	}
}

pub const max_fields = 32

pub struct Field {
pub:
	name  Span
	value Span
}

// Head is a parsed request head. Every Span indexes the message buffer.
pub struct Head {
pub mut:
	method     Method
	method_raw Span
	target     Span
	path       Span // len 0 means "/" (absolute-form target without a path)
	query      Span
	minor      int // the x of HTTP/1.x
	fields     [max_fields]Field
	nfields    int
	keep_alive bool
	host_seen  bool
	chunked    bool
}

// parse_head validates and indexes buf[0..head_end] (head_end is just past CRLFCRLF,
// as found by frame). Errors are HttpError.
@[direct_array_access]
pub fn parse_head(buf []u8, head_end int, mut h Head) ! {
	h.nfields = 0
	h.host_seen = false
	h.chunked = false
	mut conn_close := false
	mut conn_keep := false
	le := line_end(buf, 0, head_end)!
	parse_request_line(buf, le, mut h)!
	mut p := le + 2
	for p < head_end - 2 {
		e := line_end_at(buf, p, head_end)
		if e < 0 {
			return line_error(e)
		}
		if buf[p] == ` ` || buf[p] == `\t` {
			return refuse(400, 'obs-fold')
		}
		// one pass finds the colon and checks the name; a missing colon is reported
		// before a bad name, as before
		mut colon := p
		mut bad_name := false
		for colon < e && buf[colon] != `:` {
			bad_name = bad_name || !tchars[buf[colon]]
			colon++
		}
		if colon == e {
			return refuse(400, 'bad header line')
		}
		if colon == p {
			return refuse(400, 'empty header name')
		}
		if bad_name {
			return refuse(400, 'bad header name')
		}
		mut vs := colon + 1
		mut ve := e
		for vs < ve && (buf[vs] == ` ` || buf[vs] == `\t`) {
			vs++
		}
		for ve > vs && (buf[ve - 1] == ` ` || buf[ve - 1] == `\t`) {
			ve--
		}
		for k in vs .. ve {
			c := buf[k]
			if (c < 0x20 && c != `\t`) || c == 0x7f {
				return refuse(400, 'bad header value')
			}
		}
		if h.nfields == max_fields {
			return refuse(431, 'too many header fields')
		}
		name := Span{
			start: p
			len:   colon - p
		}
		value := Span{
			start: vs
			len:   ve - vs
		}
		nm := str_view(buf, name.start, name.len)
		// only four names matter here, and their lengths tell them apart
		is_host := nm.len == 4 && eq_ci(nm, 'host')
		if is_host || (nm.len == 14 && eq_ci(nm, 'content-length')) {
			for k in 0 .. h.nfields {
				if eq_ci_span(buf, h.fields[k].name, nm) {
					return refuse(400, 'duplicate framing header')
				}
			}
			if is_host {
				h.host_seen = true
			}
		} else if nm.len == 17 && eq_ci(nm, 'transfer-encoding') {
			if h.chunked {
				return refuse(400, 'duplicate transfer-encoding')
			}
			h.chunked = true
		} else if nm.len == 10 && eq_ci(nm, 'connection') {
			cf := scan_connection(buf, value)
			conn_close = conn_close || cf & 1 != 0
			conn_keep = conn_keep || cf & 2 != 0
		}
		h.fields[h.nfields] = Field{
			name:  name
			value: value
		}
		h.nfields++
		p = e + 2
	}
	if h.chunked && h.minor == 0 {
		return refuse(400, 'transfer-encoding on HTTP/1.0')
	}
	h.keep_alive = if h.minor == 1 { !conn_close } else { conn_keep && !conn_close }
}

@[direct_array_access]
fn parse_request_line(buf []u8, le int, mut h Head) ! {
	mut sp1 := -1
	mut sp2 := -1
	for k in 0 .. le {
		c := buf[k]
		if c < 0x20 || c == 0x7f {
			return refuse(400, 'bad request line')
		}
		if c == ` ` {
			if sp1 < 0 {
				sp1 = k
			} else if sp2 < 0 {
				sp2 = k
			} else {
				return refuse(400, 'bad request line')
			}
		}
	}
	if sp1 <= 0 || sp2 < 0 || sp2 == sp1 + 1 || sp2 == le - 1 {
		return refuse(400, 'bad request line')
	}
	for k in 0 .. sp1 {
		if !is_tchar(buf[k]) {
			return refuse(400, 'bad method')
		}
	}
	h.method_raw = Span{
		start: 0
		len:   sp1
	}
	h.method = method_of(str_view(buf, 0, sp1))
	ver := str_view(buf, sp2 + 1, le - sp2 - 1)
	if ver == 'HTTP/1.1' {
		h.minor = 1
	} else if ver == 'HTTP/1.0' {
		h.minor = 0
	} else if has_prefix_ci(ver, 'http/') {
		return refuse(505, 'http version not supported')
	} else {
		return refuse(400, 'bad version')
	}
	ts := sp1 + 1
	h.target = Span{
		start: ts
		len:   sp2 - ts
	}
	if sp2 - ts == 1 && buf[ts] == `*` {
		h.path = Span{
			start: ts
			len:   1
		}
		h.query = Span{
			start: sp2
			len:   0
		}
		return
	}
	mut ps := ts
	if buf[ts] != `/` {
		t := str_view(buf, ts, sp2 - ts)
		skip := if has_prefix_ci(t, 'http://') {
			7
		} else if has_prefix_ci(t, 'https://') {
			8
		} else {
			return refuse(400, 'bad request target')
		}
		ps = ts + skip
		for ps < sp2 && buf[ps] != `/` && buf[ps] != `?` {
			ps++
		}
	}
	mut q := ps
	for q < sp2 && buf[q] != `?` {
		q++
	}
	h.path = Span{
		start: ps
		len:   q - ps
	}
	h.query = if q < sp2 {
		Span{
			start: q + 1
			len:   sp2 - q - 1
		}
	} else {
		Span{
			start: sp2
			len:   0
		}
	}
}

// line_end_at is line_end without the error value, for the per-field loop: the index
// of the CR, or -1 bare LF, -2 bare CR, -3 no CRLF before limit (see line_error).
@[direct_array_access]
fn line_end_at(buf []u8, from int, limit int) int {
	mut i := from
	for i < limit {
		c := buf[i]
		if c == `\n` {
			return -1
		}
		if c == `\r` {
			if i + 1 >= limit || buf[i + 1] != `\n` {
				return -2
			}
			return i
		}
		i++
	}
	return -3
}

fn line_error(code int) IError {
	return match code {
		-1 { refuse(400, 'bare lf') }
		-2 { refuse(400, 'bare cr') }
		else { refuse(400, 'unterminated line') }
	}
}

// line_end returns the index of the CR ending the line that starts at from. A bare
// CR or LF, or no CRLF before limit, is an error.
@[direct_array_access]
fn line_end(buf []u8, from int, limit int) !int {
	mut i := from
	for i < limit {
		c := buf[i]
		if c == `\n` {
			return refuse(400, 'bare lf')
		}
		if c == `\r` {
			if i + 1 >= limit || buf[i + 1] != `\n` {
				return refuse(400, 'bare cr')
			}
			return i
		}
		i++
	}
	return refuse(400, 'unterminated line')
}

// scan_connection reads the comma-separated tokens of a Connection value.
@[direct_array_access]
fn scan_connection(buf []u8, v Span) int {
	mut flags := 0
	end := v.start + v.len
	mut i := v.start
	for i < end {
		for i < end && (buf[i] == ` ` || buf[i] == `\t` || buf[i] == `,`) {
			i++
		}
		s := i
		for i < end && buf[i] != `,` {
			i++
		}
		mut e := i
		for e > s && (buf[e - 1] == ` ` || buf[e - 1] == `\t`) {
			e--
		}
		tok := str_view(buf, s, e - s)
		if eq_ci(tok, 'close') {
			flags |= 1
		} else if eq_ci(tok, 'keep-alive') {
			flags |= 2
		}
	}
	return flags
}

// eq_ci_span compares the bytes of a with b, ignoring ASCII case on both sides.
@[direct_array_access]
fn eq_ci_span(buf []u8, a Span, b string) bool {
	if a.len != b.len {
		return false
	}
	for k in 0 .. a.len {
		if lower(buf[a.start + k]) != lower(b[k]) {
			return false
		}
	}
	return true
}

@[direct_array_access]
fn has_prefix_ci(s string, lower_lit string) bool {
	if s.len < lower_lit.len {
		return false
	}
	for k in 0 .. lower_lit.len {
		if lower(s[k]) != lower_lit[k] {
			return false
		}
	}
	return true
}
