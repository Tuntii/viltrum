module http1

// Replies from an upstream (the engine's HTTP client, Ctx.fetch): framing by RFC 9112
// section 6.3 with the same helpers requests use, so both read a message the same way.

// FetchError is how a fetch ended (Ctx.fetched).
pub enum FetchError {
	none     // a whole reply
	connect  // the upstream refused or could not be reached
	timeout  // no whole reply within the upstream's timeout
	closed   // the upstream closed before the reply was whole
	protocol // not a valid HTTP/1.1 reply
	too_big  // the reply is past the upstream's max_reply
	busy     // every connection and the queue were taken
}

// Upstream names an upstream's pool (App.upstream); pass it to Ctx.fetch.
pub struct Upstream {
pub:
	id int = -1
}

// Fetched is the reply a fetch callback gets (Ctx.fetched). body points into the
// upstream connection's buffer and is valid until the callback returns.
pub struct Fetched {
pub:
	err    FetchError = .timeout
	status int
	body   []u8
}

// ReplyFrame is the resumable framing state of the reply at the front of a buffer.
pub struct ReplyFrame {
pub mut:
	scanned        int
	head_end       int // just past CRLFCRLF; 0 until the head is whole
	status         int
	content_length int = -1
	chunked        bool
	chunk          ChunkScan
	until_close    bool // the body ends when the upstream closes
	keep           bool // the connection can carry another request after this reply
	interim        bool // a 1xx head: drop it and frame what follows
}

pub fn (mut f ReplyFrame) reset() {
	f = ReplyFrame{}
}

// frame_reply returns the length of the whole reply at the front of buf, or -1 when
// more bytes are needed. head is whether the request was HEAD; eof is whether the
// upstream has closed, which ends a body without a length. With f.interim set, the
// length is that of a 1xx head to drop. Errors carry 413 past max, 503 for a reply
// the upstream cut short by closing, else 502.
pub fn frame_reply(buf []u8, mut f ReplyFrame, head bool, eof bool, max int) !int {
	if f.head_end == 0 {
		end := find_head_end(buf, f.scanned)
		if end < 0 {
			if buf.len > max {
				return refuse(413, 'reply too large')
			}
			if eof && buf.len > 0 {
				return refuse(503, 'reply cut short')
			}
			f.scanned = if buf.len > 3 { buf.len - 3 } else { 0 }
			return -1
		}
		f.head_end = end
		h := view(buf, 0, end)
		if !clean_head(h) {
			return refuse(502, 'bad reply head')
		}
		minor := status_line(h, mut f)!
		if f.status < 200 {
			if f.status == 101 {
				return refuse(502, 'unexpected upgrade')
			}
			f.interim = true
			return end
		}
		mut te := Span{}
		mut cl := Span{}
		mut ex := Span{}
		framing_fields(h, mut te, mut cl, mut ex)
		conn := header_value(h, 'connection')
		f.keep = if minor == 0 {
			conn.found() && has_token(h, conn, 'keep-alive')
		} else {
			!(conn.found() && has_token(h, conn, 'close'))
		}
		if head || f.status == 204 || f.status == 304 {
			f.content_length = 0
		} else if te.found() {
			if cl.found() || !eq_ci(str_view(h, te.start, te.len), 'chunked') {
				return refuse(502, 'bad transfer-encoding')
			}
			f.chunked = true
			f.chunk = ChunkScan.new(end)
		} else if cl.found() {
			n := parse_content_length(view(h, cl.start, cl.len)) or {
				return refuse(502, 'bad content-length')
			}
			if n > max {
				return refuse(413, 'reply too large')
			}
			f.content_length = int(n)
		} else {
			f.until_close = true
			f.keep = false
		}
	}
	if f.chunked {
		return frame_reply_chunked(buf, mut f, eof, max)
	}
	if f.until_close {
		if buf.len - f.head_end > max {
			return refuse(413, 'reply too large')
		}
		return if eof { buf.len } else { -1 }
	}
	total := f.head_end + f.content_length
	if buf.len < total {
		if eof {
			return refuse(503, 'reply cut short')
		}
		return -1
	}
	return total
}

// frame_reply_chunked is frame_reply's chunked tail, apart for the same reason as
// frame_chunked.
fn frame_reply_chunked(buf []u8, mut f ReplyFrame, eof bool, max int) !int {
	done := scan_chunked(buf, mut f.chunk, max) or {
		if err.code() == 413 {
			return err
		}
		return refuse(502, 'bad chunked reply')
	}
	if !done {
		if eof {
			return refuse(503, 'reply cut short')
		}
		return -1
	}
	return f.chunk.pos
}

// status_line reads "HTTP/1.x NNN reason" into f.status and returns x.
@[direct_array_access]
fn status_line(h []u8, mut f ReplyFrame) !int {
	if h.len < 13 || h[0] != `H` || h[1] != `T` || h[2] != `T` || h[3] != `P`
		|| h[4] != `/` || h[5] != `1` || h[6] != `.` || (h[7] != `0` && h[7] != `1`)
		|| h[8] != ` ` {
		return refuse(502, 'bad status line')
	}
	mut s := 0
	for i in 9 .. 12 {
		if h[i] < `0` || h[i] > `9` {
			return refuse(502, 'bad status line')
		}
		s = s * 10 + int(h[i] - `0`)
	}
	if s < 100 || (h[12] != ` ` && h[12] != `\r`) {
		return refuse(502, 'bad status line')
	}
	f.status = s
	return int(h[7] - `0`)
}

// clean_head is whether a reply head has CR and LF only as CRLF pairs and no NUL. A
// handler may copy a reply header into its own response, so a bare CR or LF from the
// upstream must not reach one.
@[direct_array_access]
fn clean_head(h []u8) bool {
	for i in 0 .. h.len {
		c := h[i]
		if c == `\r` {
			if i + 1 >= h.len || h[i + 1] != `\n` {
				return false
			}
		} else if c == `\n` {
			if i == 0 || h[i - 1] != `\r` {
				return false
			}
		} else if c == 0 {
			return false
		}
	}
	return true
}

// has_token is whether the comma-separated list at s holds token (any case).
@[direct_array_access]
fn has_token(h []u8, s Span, token string) bool {
	mut i := s.start
	end := s.start + s.len
	for i < end {
		for i < end && (h[i] == ` ` || h[i] == `\t` || h[i] == `,`) {
			i++
		}
		mut j := i
		for j < end && h[j] != `,` && h[j] != ` ` && h[j] != `\t` {
			j++
		}
		if j - i == token.len && eq_ci(str_view(h, i, j - i), token) {
			return true
		}
		i = j
	}
	return false
}

// reply_body is the body of a reply frame_reply accepted. A chunked body is decoded
// in place, behind its chunk lines, so it may be read only once.
pub fn reply_body(buf []u8, f &ReplyFrame, n int) []u8 {
	if f.chunked {
		return view(buf, f.head_end, undo_chunked(buf, f.head_end))
	}
	return view(buf, f.head_end, n - f.head_end)
}

// undo_chunked moves the data of the chunked body at buf[start..] to start, in
// place (what is written never passes what is read), and returns its length. The
// syntax is not re-checked: scan_chunked accepted it.
@[direct_array_access]
fn undo_chunked(buf []u8, start int) int {
	mut i := start
	mut o := start
	for {
		mut size := 0
		for i < buf.len {
			v := hex_value(buf[i])
			if v < 0 {
				break
			}
			size = size * 16 + v
			i++
		}
		for i < buf.len && buf[i] != `\n` {
			i++
		}
		i++
		if size == 0 || i + size > buf.len {
			return o - start
		}
		unsafe { C.memmove(&u8(buf.data) + o, &u8(buf.data) + i, size) }
		o += size
		i += size + 2
	}
	return o - start
}

// reply_header is the first field of the reply head named name (any case).
@[direct_array_access]
pub fn reply_header(head []u8, name string) ?string {
	mut i := crlf_at(head, 0) + 2
	for i + 1 < head.len {
		j := crlf_at(head, i)
		if j == i {
			break
		}
		if j - i > name.len && head[i + name.len] == `:` {
			mut ok := true
			for k in 0 .. name.len {
				if lower(head[i + k]) != lower(name[k]) {
					ok = false
					break
				}
			}
			if ok {
				mut s := i + name.len + 1
				mut e := j
				for s < e && (head[s] == ` ` || head[s] == `\t`) {
					s++
				}
				for e > s && (head[e - 1] == ` ` || head[e - 1] == `\t`) {
					e--
				}
				return str_view(head, s, e - s)
			}
		}
		i = j + 2
	}
	return none
}
