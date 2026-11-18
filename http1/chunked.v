module http1

// Chunked request bodies (RFC 9112 section 7.1). frame() accepts a chunked body with
// scan_chunked; the engine then copies its data out with decode_chunked. Both walk
// the same bytes, so they cannot disagree on where the message ends.

const max_chunk_size_digits = 8 // 0xffffffff; the body limit cuts in long before
const max_chunk_trailer_bytes = 8192
const max_chunk_line_bytes = 4096 // size line including extensions
const max_chunk_overhead = 16 * 1024 // framing bytes allowed past the data they carry

// ChunkScan is resumable framing state. pos is an offset into the buffer passed to
// scan_chunked and only moves past complete units, so a client sending one byte at
// a time costs one pass over the body, not one pass per read.
pub struct ChunkScan {
pub mut:
	pos int
mut:
	total         int
	overhead      int // size lines and CRLFs of the chunks so far
	in_trailers   bool
	trailer_bytes int
}

pub fn ChunkScan.new(body_start int) ChunkScan {
	return ChunkScan{
		pos: body_start
	}
}

// scan_chunked advances st over buf and returns true once the whole chunked body
// (last chunk, trailers and the final CRLF) is in buf; st.pos is then the message
// end. It returns false when more bytes are needed.
pub fn scan_chunked(buf []u8, mut st ChunkScan, max_body int) !bool {
	for !st.in_trailers {
		mut i := st.pos
		mut size := i64(0)
		mut digits := 0
		for i < buf.len {
			v := hex_value(buf[i])
			if v < 0 {
				break
			}
			digits++
			if digits > max_chunk_size_digits {
				return refuse(400, 'bad chunk size')
			}
			size = size * 16 + i64(v)
			i++
		}
		if i >= buf.len {
			return false
		}
		if digits == 0 {
			return refuse(400, 'bad chunk size')
		}
		ws := i
		for i < buf.len && (buf[i] == ` ` || buf[i] == `\t`) {
			i++
		}
		if i >= buf.len {
			if buf.len - st.pos > max_chunk_line_bytes {
				return refuse(400, 'chunk line too long')
			}
			return false
		}
		// whitespace may only come before an extension's ";" (BWS), not before the CRLF
		if buf[i] != `;` && (buf[i] != `\r` || i > ws) {
			return refuse(400, 'bad chunk size')
		}
		ext := i
		i = chunk_line_end(buf, i)!
		if i < 0 {
			if buf.len - st.pos > max_chunk_line_bytes {
				return refuse(400, 'chunk line too long')
			}
			return false
		}
		if i - st.pos > max_chunk_line_bytes {
			return refuse(400, 'chunk line too long')
		}
		if buf[ext] == `;` && !chunk_ext_ok(buf, ext, i - 2) {
			return refuse(400, 'bad chunk extension')
		}
		if size == 0 {
			st.pos = i
			st.in_trailers = true
			break
		}
		if i64(st.total) + size > i64(max_body) {
			return refuse(413, 'payload too large')
		}
		n := int(size)
		if buf.len < i + n + 2 {
			return false
		}
		if buf[i + n] != `\r` || buf[i + n + 1] != `\n` {
			return refuse(400, 'bad chunk data')
		}
		st.total += n
		st.overhead += i - st.pos + 2
		// a body of tiny chunks costs the framing more than it carries: the whole message
		// is buffered, so a megabyte of data in 1-byte chunks would hold six
		if st.overhead > max_chunk_overhead && st.overhead > st.total {
			return refuse(413, 'payload too large')
		}
		st.pos = i + n + 2
	}
	// trailer-section: field lines until an empty line. Trailers are dropped.
	for {
		start := st.pos
		i := chunk_line_end(buf, start)!
		if i < 0 {
			if buf.len - start > max_chunk_trailer_bytes {
				return refuse(431, 'chunk trailers too large')
			}
			return false
		}
		st.pos = i
		if i == start + 2 {
			return true
		}
		st.trailer_bytes += i - start
		if st.trailer_bytes > max_chunk_trailer_bytes {
			return refuse(431, 'chunk trailers too large')
		}
		mut colon := start
		for colon < i - 2 && buf[colon] != `:` {
			colon++
		}
		if colon == start || colon >= i - 2 {
			return refuse(400, 'bad chunk trailer')
		}
		for k in start .. colon {
			if !is_tchar(buf[k]) {
				return refuse(400, 'bad chunk trailer')
			}
		}
	}
	return false
}

// decode_chunked appends the data of a chunked body that scan_chunked accepted to
// out. The syntax is not re-checked.
pub fn decode_chunked(buf []u8, start int, mut out []u8) {
	mut i := start
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
			return
		}
		unsafe { out.push_many(&u8(buf.data) + i, size) }
		i += size + 2
	}
}

// chunk_line_end returns the offset just past the CRLF that ends the line at from,
// -1 when buf ends first, or an error for a bare CR/LF or another control byte.
fn chunk_line_end(buf []u8, from int) !int {
	mut i := from
	for i < buf.len {
		c := buf[i]
		if c == `\r` {
			if i + 1 >= buf.len {
				return -1
			}
			if buf[i + 1] != `\n` {
				return refuse(400, 'bare cr')
			}
			return i + 2
		}
		if (c < 0x20 && c != `\t`) || c == 0x7f {
			return refuse(400, 'control byte in chunk line')
		}
		i++
	}
	return -1
}

// chunk_ext_ok checks buf[from..end], which starts at a ";", against chunk-ext:
// *( BWS ";" BWS name [ BWS "=" BWS ( token / quoted-string ) ] ). Extensions are
// dropped, but one we would read differently from a proxy is refused.
@[direct_array_access]
fn chunk_ext_ok(buf []u8, from int, end int) bool {
	mut i := from
	for i < end {
		i = skip_bws(buf, i, end)
		if i >= end {
			return true
		}
		if buf[i] != `;` {
			return false
		}
		i = skip_bws(buf, i + 1, end)
		s := i
		for i < end && tchars[buf[i]] {
			i++
		}
		if i == s {
			return false
		}
		j := skip_bws(buf, i, end)
		if j >= end || buf[j] != `=` {
			i = j
			continue
		}
		i = skip_bws(buf, j + 1, end)
		if i < end && buf[i] == `"` {
			i++
			for i < end && buf[i] != `"` {
				if buf[i] == `\\` {
					i++
				}
				i++
			}
			if i >= end {
				return false
			}
			i++
		} else {
			v := i
			for i < end && tchars[buf[i]] {
				i++
			}
			if i == v {
				return false
			}
		}
	}
	return true
}

fn skip_bws(buf []u8, from int, end int) int {
	mut i := from
	for i < end && (buf[i] == ` ` || buf[i] == `\t`) {
		i++
	}
	return i
}

fn hex_value(c u8) int {
	return match true {
		c >= `0` && c <= `9` { int(c - `0`) }
		c >= `a` && c <= `f` { int(c - `a`) + 10 }
		c >= `A` && c <= `F` { int(c - `A`) + 10 }
		else { -1 }
	}
}
