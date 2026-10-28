module http1

// Framing: find where the message at the front of a buffer ends, so pipelined
// requests can be served from one read. Content-Length and chunked only; anything
// a front proxy could read differently is refused (request smuggling).

pub struct Limits {
pub:
	max_header_bytes int = 64 * 1024
	max_body_bytes   int = 1024 * 1024
	max_headers      int = 32
}

// HttpError is a request the engine refuses: it answers `status` and closes.
pub struct HttpError {
	Error
pub:
	status int
	reason string
}

pub fn (e HttpError) msg() string {
	return e.reason
}

pub fn (e HttpError) code() int {
	return e.status
}

// cold: errors close the connection, so boxing them is off the hot path.
fn refuse(status int, reason string) IError {
	return IError(HttpError{
		status: status
		reason: reason
	})
}

// Span is a byte range of a buffer; start < 0 means absent.
pub struct Span {
pub:
	start int = -1
	len   int
}

pub fn (s Span) found() bool {
	return s.start >= 0
}

// Frame is the resumable framing state of the message at the front of a buffer.
pub struct Frame {
pub mut:
	scanned         int // the header terminator search resumes here
	head_end        int // index just past CRLFCRLF; 0 until the head is complete
	content_length  int
	chunked         bool
	chunk           ChunkScan
	expect_continue bool
	continue_sent   bool
}

pub fn (mut f Frame) reset() {
	f = Frame{}
}

// frame returns the length of the complete message at the front of buf, or -1 when
// more bytes are needed. f must be reset between messages. Errors are HttpError.
pub fn frame(buf []u8, mut f Frame, lim Limits) !int {
	if f.head_end == 0 {
		end := find_head_end(buf, f.scanned)
		if end < 0 {
			if buf.len > lim.max_header_bytes {
				return refuse(431, 'headers too large')
			}
			f.scanned = if buf.len > 3 { buf.len - 3 } else { 0 }
			return -1
		}
		if end > lim.max_header_bytes {
			return refuse(431, 'headers too large')
		}
		f.head_end = end
		head := view(buf, 0, end)
		mut te := Span{}
		mut cl := Span{}
		mut ex := Span{}
		framing_fields(head, mut te, mut cl, mut ex)
		if te.found() && cl.found() {
			return refuse(400, 'transfer-encoding and content-length conflict')
		}
		if te.found() {
			if !eq_ci(str_view(head, te.start, te.len), 'chunked') {
				return refuse(400, 'transfer-encoding not supported')
			}
			f.chunked = true
			f.chunk = ChunkScan.new(end)
		} else if cl.found() {
			n := parse_content_length(view(head, cl.start, cl.len)) or {
				return refuse(400, 'bad content-length')
			}
			if n > lim.max_body_bytes {
				return refuse(413, 'payload too large')
			}
			f.content_length = int(n)
		}
		f.expect_continue = ex.found() && eq_ci(str_view(head, ex.start, ex.len), '100-continue')
	}
	if f.chunked {
		return frame_chunked(buf, mut f, lim)
	}
	total := f.head_end + f.content_length
	if buf.len < total {
		return -1
	}
	return total
}

// frame_chunked is frame's chunked tail. A `!` in frame itself makes V master move
// the spans above to the heap, three allocations a request.
fn frame_chunked(buf []u8, mut f Frame, lim Limits) !int {
	if !scan_chunked(buf, mut f.chunk, lim.max_body_bytes)! {
		return -1
	}
	return f.chunk.pos
}

// find_head_end returns the index just past the first CRLFCRLF at or after from, or -1.
@[direct_array_access]
fn find_head_end(buf []u8, from int) int {
	// jump from LF to LF with memchr: the terminator ends at an LF with CR LF CR
	// before it, at index from + 3 or later
	mut i := from + 3
	for i < buf.len {
		p := unsafe { C.memchr(&u8(buf.data) + i, `\n`, u64(buf.len - i)) }
		if isnil(p) {
			return -1
		}
		i = int(unsafe { &u8(p) - &u8(buf.data) })
		if buf[i - 1] == `\r` && buf[i - 2] == `\n` && buf[i - 3] == `\r` {
			return i + 1
		}
		i++
	}
	return -1
}

// header_value finds the first field named name_lower (ASCII lowercase) in a
// request head and returns its value with OWS trimmed. The request line is skipped,
// lines are split on CRLF only (the parser rejects bare CR/LF later).
@[direct_array_access]
pub fn header_value(head []u8, name_lower string) Span {
	mut i := 0
	for i + 1 < head.len && !(head[i] == `\r` && head[i + 1] == `\n`) {
		i++
	}
	i += 2
	for i + 1 < head.len {
		mut j := i
		for j + 1 < head.len && !(head[j] == `\r` && head[j + 1] == `\n`) {
			j++
		}
		if j == i {
			break
		}
		if j - i > name_lower.len && head[i + name_lower.len] == `:` {
			mut ok := true
			for k in 0 .. name_lower.len {
				if lower(head[i + k]) != name_lower[k] {
					ok = false
					break
				}
			}
			if ok {
				mut s := i + name_lower.len + 1
				mut e := j
				for s < e && (head[s] == ` ` || head[s] == `\t`) {
					s++
				}
				for e > s && (head[e - 1] == ` ` || head[e - 1] == `\t`) {
					e--
				}
				return Span{
					start: s
					len:   e - s
				}
			}
		}
		i = j + 2
	}
	return Span{}
}

// framing_fields finds the first Transfer-Encoding, Content-Length and Expect fields
// of a head in one pass, by header_value's rules: lines split on CRLF, the name
// directly before the colon, the value with OWS trimmed. Only lines starting with
// t, c or e are compared.
@[direct_array_access]
fn framing_fields(head []u8, mut te Span, mut cl Span, mut ex Span) {
	mut i := crlf_at(head, 0) + 2
	for i + 1 < head.len {
		j := crlf_at(head, i)
		if j == i {
			break
		}
		c := head[i] | 0x20
		if c == `t` {
			field_at(head, i, j, 'transfer-encoding', mut te)
		} else if c == `c` {
			field_at(head, i, j, 'content-length', mut cl)
		} else if c == `e` {
			field_at(head, i, j, 'expect', mut ex)
		}
		i = j + 2
	}
}

// crlf_at is the index of the CR of the first CRLF at or after i, or head.len - 1
// when there is none (header_value's scan, with memchr between LFs).
@[direct_array_access]
fn crlf_at(head []u8, i int) int {
	mut k := i + 1
	for k < head.len {
		p := unsafe { C.memchr(&u8(head.data) + k, `\n`, u64(head.len - k)) }
		if isnil(p) {
			break
		}
		k = int(unsafe { &u8(p) - &u8(head.data) })
		if head[k - 1] == `\r` {
			return k - 1
		}
		k++
	}
	return if head.len > i { head.len - 1 } else { i }
}

// field_at sets s to the value of the line head[i..j] when it is the first field named
// name_lower.
@[direct_array_access]
fn field_at(head []u8, i int, j int, name_lower string, mut s Span) {
	if s.found() || j - i <= name_lower.len || head[i + name_lower.len] != `:` {
		return
	}
	for k in 0 .. name_lower.len {
		if lower(head[i + k]) != name_lower[k] {
			return
		}
	}
	mut vs := i + name_lower.len + 1
	mut ve := j
	for vs < ve && (head[vs] == ` ` || head[vs] == `\t`) {
		vs++
	}
	for ve > vs && (head[ve - 1] == ` ` || head[ve - 1] == `\t`) {
		ve--
	}
	s = Span{
		start: vs
		len:   ve - vs
	}
}

// parse_content_length accepts 1*DIGIT only (RFC 9112 section 6.3): no sign or list.
// A value past what an int holds stops growing there, so it is refused with 413 like
// any other length over the limit rather than taken for a malformed one.
@[direct_array_access]
fn parse_content_length(b []u8) ?i64 {
	if b.len == 0 {
		return none
	}
	mut n := i64(0)
	for c in b {
		if c < `0` || c > `9` {
			return none
		}
		if n <= max_i32 {
			n = n * 10 + i64(c - `0`)
		}
	}
	return n
}
