module http1

#include "@VMODROOT/http1/file.h"

@[typedef]
pub struct C.viltrum_file_info {
pub mut:
	size     i64
	mtime    i64
	mtime_ns i64
	kind     int
}

fn C.viltrum_file_open(path &u8, info &C.viltrum_file_info) int
fn C.viltrum_file_pread(fd int, buf voidptr, n u64, off i64) i64
fn C.viltrum_file_close(fd int)

// file_inline_max: a file this size or smaller goes out with its head in one write.
// A larger one is not read by the handler; the engine streams it from the open file
// after the head (sendfile on cleartext connections).
pub const file_inline_max = 64 * 1024

@[params]
pub struct FileOptions {
pub:
	content_type string // '' picks one from the file name's extension
	max_age      int = -1 // seconds for Cache-Control; -1 sends no Cache-Control
}

@[params]
pub struct StaticOptions {
pub:
	index    string = 'index.html' // served for a directory; '' answers 404 instead
	max_age  int    = -1           // seconds for Cache-Control; -1 sends no Cache-Control
	dotfiles bool // serve names starting with '.' (.env, .git/...); refused by default
	// precompressed serves name.br or name.gz, the copies compressed ahead of time
	// beside a file, to a client that accepts that coding (br first), with the file's
	// own Content-Type; every answer then carries Vary: Accept-Encoding. Like the
	// files themselves, the copies are read from disk on each request.
	precompressed bool
}

// file answers with the file at path. GET and HEAD carry validators (ETag,
// Last-Modified) and get 304 for a matching If-None-Match or If-Modified-Since; a GET
// may ask for one byte range (206, or 416 past the end). A missing, unreadable or
// non-regular file answers 404. The answer bypasses capture, so gzip leaves it alone.
pub fn (mut c Ctx) file(path string, o FileOptions) {
	if c.responded || c.deferred {
		$if viltrum_debug ? {
			panic('viltrum: file() on a request that already has a response')
		}
		return
	}
	unsafe {
		c.pbuf.len = 0
	}
	for k in 0 .. path.len {
		if path[k] == 0 {
			c.text(404, 'not found')
			return
		}
	}
	append_str(mut c.pbuf, path)
	info := &c.finfo[0]
	fd := c.open_pbuf(info)
	if fd < 0 || info.kind != 1 {
		if fd >= 0 {
			C.viltrum_file_close(fd)
		}
		c.text(404, 'not found')
		return
	}
	ct := if o.content_type.len > 0 { o.content_type } else { content_type_for(path) }
	c.send_file(fd, info, ct, '', o.max_age)
}

// static_file answers a GET or HEAD for rel, the still percent-encoded rest of the
// URL path, under dir; App.static is the usual way in. A directory serves its index,
// after a redirect that adds the trailing slash relative links need. A path with an
// empty name is collapsed; one naming '.' or '..', or holding NUL or a backslash,
// answers 404 and is never opened, so nothing outside dir is reachable through the
// URL. Dotfiles answer 404 too unless o.dotfiles is set.
pub fn (mut c Ctx) static_file(dir string, rel string, o StaticOptions) {
	c.static_file_at(dir, rel, &o)
}

// static_file_at is static_file with the options behind a pointer: what
// App.static_files calls, since V -prod pins an options struct passed by value around
// every call in the function.
pub fn (mut c Ctx) static_file_at(dir string, rel string, o &StaticOptions) {
	if c.responded || c.deferred {
		return
	}
	if c.head.method != .get && c.head.method != .head {
		c.set_header('Allow', 'GET, HEAD')
		c.text(405, 'method not allowed')
		return
	}
	unsafe {
		c.pbuf.len = 0
	}
	append_str(mut c.pbuf, if dir.len > 0 { dir } else { '.' })
	if c.pbuf[c.pbuf.len - 1] != `/` {
		c.pbuf << `/`
	}
	if !c.append_rel(rel, o.dotfiles) {
		c.text(404, 'not found')
		return
	}
	if c.pbuf.len > 1 && c.pbuf[c.pbuf.len - 1] == `/` {
		unsafe {
			c.pbuf.len-- // dir itself: Windows' stat refuses a trailing slash
		}
	}
	info := &c.finfo[0]
	mut fd := c.open_pbuf(info)
	if info.kind == 2 {
		path := c.path()
		if path.len == 0 || path[path.len - 1] != `/` {
			c.redirect_slash()
			return
		}
		if o.index.len > 0 {
			if c.pbuf[c.pbuf.len - 1] != `/` {
				c.pbuf << `/`
			}
			append_str(mut c.pbuf, o.index)
			fd = c.open_pbuf(info)
		}
	}
	if fd < 0 || info.kind != 1 {
		if fd >= 0 {
			C.viltrum_file_close(fd)
		}
		c.text(404, 'not found')
		return
	}
	ct := content_type_for(str_view(c.pbuf, 0, c.pbuf.len))
	if !o.precompressed {
		c.send_file(fd, info, ct, '', o.max_age)
		return
	}
	c.set_header('Vary', 'Accept-Encoding')
	ae := c.header('accept-encoding') or { '' }
	for k in 0 .. 2 {
		coding := if k == 0 { 'br' } else { 'gzip' }
		if !accepts_coding(ae, coding) {
			continue
		}
		mark := c.pbuf.len
		append_str(mut c.pbuf, if coding == 'br' { '.br' } else { '.gz' })
		vinfo := &c.finfo[1]
		vfd := c.open_pbuf(vinfo)
		unsafe {
			c.pbuf.len = mark
		}
		if vfd >= 0 && vinfo.kind == 1 {
			C.viltrum_file_close(fd)
			c.send_file(vfd, vinfo, ct, coding, o.max_age)
			return
		}
		if vfd >= 0 {
			C.viltrum_file_close(vfd)
		}
	}
	c.send_file(fd, info, ct, '', o.max_age)
}

// append_rel decodes rel onto pbuf name by name; false for a name that must not be
// opened. A decoded %2F separates names like '/' does, so it cannot smuggle '..'.
fn (mut c Ctx) append_rel(rel string, dotfiles bool) bool {
	base := c.pbuf.len
	mut start := base
	mut i := 0
	for i <= rel.len {
		mut b := u8(`/`)
		if i < rel.len {
			b = rel[i]
			if b == `%` {
				if i + 2 >= rel.len {
					return false
				}
				hi := hex_value(rel[i + 1])
				lo := hex_value(rel[i + 2])
				if hi < 0 || lo < 0 {
					return false
				}
				b = u8(hi * 16 + lo)
				i += 2
			}
		}
		i++
		if b != `/` {
			if b == 0 || b == `\\` {
				return false
			}
			c.pbuf << b
			continue
		}
		n := c.pbuf.len - start
		if n == 0 {
			continue // an empty name: '//' or a leading or trailing '/'
		}
		if c.pbuf[start] == `.` && (!dotfiles || n == 1 || (n == 2 && c.pbuf[start + 1] == `.`)) {
			return false
		}
		c.pbuf << `/`
		start = c.pbuf.len
	}
	if c.pbuf.len > base && start == c.pbuf.len {
		unsafe {
			c.pbuf.len--
		}
	}
	return true
}

// redirect_slash answers 301 to the request path with a '/' added, query kept.
fn (mut c Ctx) redirect_slash() {
	path := c.path()
	mut s := 0
	for s + 1 < path.len && path[s] == `/` && path[s + 1] == `/` {
		s++ // never '//host': a client reads that as another site
	}
	unsafe {
		c.pbuf.len = 0
	}
	append_str(mut c.pbuf, sub_view(path, s, path.len - s))
	c.pbuf << `/`
	q := c.query()
	if q.len > 0 {
		c.pbuf << `?`
		append_str(mut c.pbuf, q)
	}
	c.set_header('Location', str_view(c.pbuf, 0, c.pbuf.len))
	c.text(301, 'moved permanently')
}

// open_pbuf opens the path in pbuf; -1 when it cannot be opened.
fn (mut c Ctx) open_pbuf(info &C.viltrum_file_info) int {
	c.pbuf << 0
	fd := C.viltrum_file_open(c.pbuf.data, info)
	unsafe {
		c.pbuf.len--
	}
	return fd
}

// send_file answers with the open file fd, which it takes over (closes or hands to
// the engine); coding names the Content-Encoding its bytes are in, '' for none.
fn (mut c Ctx) send_file(fd int, info &C.viltrum_file_info, content_type string, coding string, max_age int) {
	etag := c.make_etag(info)
	format_imf(info.mtime, &c.lastmod[0])
	c.set_header('ETag', etag)
	c.set_header('Last-Modified', unsafe { tos(&c.lastmod[0], 29) })
	if max_age >= 0 {
		c.set_header('Cache-Control', c.max_age_value(max_age))
	}
	method := c.head.method
	if (method == .get || method == .head) && c.not_modified(etag, info.mtime) {
		C.viltrum_file_close(fd)
		c.answer_head(304, '', '', -1)
		return
	}
	c.set_header('Accept-Ranges', 'bytes')
	mut status := 200
	mut off := i64(0)
	mut n := info.size
	if method == .get && info.size > 0 && c.if_range_holds(etag, info.mtime) {
		if r := c.header('range') {
			start, end := parse_range(r, info.size)
			if start == range_unsatisfiable {
				C.viltrum_file_close(fd)
				c.set_header('Content-Range', c.content_range(-1, -1, info.size))
				c.answer_head(416, '', '', 0)
				return
			}
			if start >= 0 {
				status = 206
				off = start
				n = end - start + 1
				c.set_header('Content-Range', c.content_range(start, end, info.size))
			}
		}
	}
	if method == .head || n == 0 {
		C.viltrum_file_close(fd)
		c.answer_head(status, content_type, coding, n)
		return
	}
	if n > file_inline_max {
		c.answer_head(status, content_type, coding, n)
		c.file_fd = fd
		c.file_off = off
		c.file_left = n
		return
	}
	mark := c.out.len
	c.answer_head(status, content_type, coding, n)
	if c.out.cap - c.out.len < n {
		unsafe { c.out.grow_cap(int(n)) } // cold: a write buffer smaller than the file
	}
	got := read_at(fd, unsafe { &u8(c.out.data) + c.out.len }, n, off)
	C.viltrum_file_close(fd)
	if got != n {
		// the file shrank or failed under us: take the head back and say so
		unsafe {
			c.out.len = mark
		}
		c.responded = false
		c.wrote = false
		c.nextra = 0
		c.close()
		c.text(500, 'internal error')
		return
	}
	unsafe {
		c.out.len += int(n)
	}
}

// answer_head marks the response written and writes its head; length as write_head.
fn (mut c Ctx) answer_head(status int, content_type string, coding string, length i64) {
	c.responded = true
	c.wrote = true
	c.status = status
	c.write_head(status, content_type, coding, length)
}

// read_at reads n bytes at off into p, short only at the end of the file or on error.
pub fn read_at(fd int, p &u8, n i64, off i64) i64 {
	mut got := i64(0)
	for got < n {
		r := C.viltrum_file_pread(fd, unsafe { p + got }, u64(n - got), off + got)
		if r <= 0 {
			break
		}
		got += r
	}
	return got
}

// close_file closes a file the engine was streaming.
pub fn close_file(fd int) {
	C.viltrum_file_close(fd)
}

// make_etag is "mtime-size" in hex (with the nanoseconds where the platform has them),
// which changes whenever the file is replaced or rewritten.
fn (mut c Ctx) make_etag(info &C.viltrum_file_info) string {
	unsafe {
		mut p := &c.etag[0]
		p[0] = `"`
		p = put_hex(p + 1, u64(info.mtime))
		if info.mtime_ns != 0 {
			p[0] = `.`
			p = put_hex(p + 1, u64(info.mtime_ns))
		}
		p[0] = `-`
		p = put_hex(p + 1, u64(info.size))
		p[0] = `"`
		return tos(&c.etag[0], int(p + 1 - &c.etag[0]))
	}
}

fn (mut c Ctx) max_age_value(secs int) string {
	unsafe {
		mut p := put_str(&c.crange[0], 'max-age=')
		p = put_uint(p, u64(secs))
		return tos(&c.crange[0], int(p - &c.crange[0]))
	}
}

// content_range is "bytes start-end/size", or "bytes */size" for start < 0. It shares
// crange with max_age_value, so it goes past the end of that one.
fn (mut c Ctx) content_range(start i64, end i64, size i64) string {
	unsafe {
		base := &c.crange[24]
		mut p := put_str(base, 'bytes ')
		if start < 0 {
			p[0] = `*`
			p++
		} else {
			p = put_uint(p, u64(start))
			p[0] = `-`
			p = put_uint(p + 1, u64(end))
		}
		p[0] = `/`
		p = put_uint(p + 1, u64(size))
		return tos(base, int(p - base))
	}
}

@[inline; unsafe]
fn put_hex(p &u8, n u64) &u8 {
	mut tmp := [16]u8{}
	mut i := 16
	mut v := n
	for {
		i--
		tmp[i] = '0123456789abcdef'[int(v & 15)]
		v >>= 4
		if v == 0 {
			break
		}
	}
	unsafe {
		C.memcpy(p, &tmp[i], 16 - i)
		return p + (16 - i)
	}
}

// not_modified: If-None-Match decides when present (weak comparison, RFC 9110
// 13.1.2); otherwise If-Modified-Since, against the file's whole seconds.
fn (c &Ctx) not_modified(etag string, mtime i64) bool {
	if inm := c.header('if-none-match') {
		return etag_listed(inm, etag)
	}
	if ims := c.header('if-modified-since') {
		t := parse_imf(ims) or { return false }
		return mtime <= t
	}
	return false
}

// if_range_holds: a Range is honored only while If-Range, if sent, still names this
// file: the same strong ETag or exactly its Last-Modified.
fn (c &Ctx) if_range_holds(etag string, mtime i64) bool {
	v := c.header('if-range') or { return true }
	if v.len > 0 && v[0] == `"` {
		return v == etag
	}
	t := parse_imf(v) or { return false }
	return t == mtime
}

// etag_listed reports whether list (an If-None-Match value) holds etag or '*',
// ignoring weakness.
fn etag_listed(list string, etag string) bool {
	mut i := 0
	for i < list.len {
		for i < list.len && (list[i] == ` ` || list[i] == `\t` || list[i] == `,`) {
			i++
		}
		if i < list.len && list[i] == `*` {
			return true
		}
		if i + 1 < list.len && list[i] == `W` && list[i + 1] == `/` {
			i += 2
		}
		s := i
		if i < list.len && list[i] == `"` {
			i++
			for i < list.len && list[i] != `"` {
				i++
			}
			i++
		}
		if i > list.len {
			return false
		}
		// the tag must end the entry: '"x"y' names nothing
		ends := i == list.len || list[i] == ` ` || list[i] == `\t` || list[i] == `,`
		if ends && i - s == etag.len && sub_view(list, s, i - s) == etag {
			return true
		}
		for i < list.len && list[i] != `,` {
			i++
		}
	}
	return false
}

const range_ignore = i64(-1)
const range_unsatisfiable = i64(-2)

// parse_range reads a Range value for a file of size bytes: the first and last byte
// of the one range asked for, range_unsatisfiable when it starts past the end, or
// range_ignore (serve the whole file) for anything else: another unit, a malformed
// value, or several ranges, which a server may answer in full.
fn parse_range(v string, size i64) (i64, i64) {
	mut i := 0
	for i < v.len && (v[i] == ` ` || v[i] == `\t`) {
		i++
	}
	if v.len - i < 6 || lower(v[i]) != `b` || lower(v[i + 1]) != `y` || lower(v[i + 2]) != `t`
		|| lower(v[i + 3]) != `e` || lower(v[i + 4]) != `s` || v[i + 5] != `=` {
		return range_ignore, range_ignore
	}
	i += 6
	mut e := v.len
	for e > i && (v[e - 1] == ` ` || v[e - 1] == `\t`) {
		e--
	}
	first, ni := range_num(v, i, e)
	if ni >= e || v[ni] != `-` {
		return range_ignore, range_ignore
	}
	last, ne := range_num(v, ni + 1, e)
	if ne != e {
		return range_ignore, range_ignore // trailing bytes, or a second range
	}
	if first < 0 {
		// "-n": the last n bytes
		if last <= 0 {
			return if last == 0 { range_unsatisfiable } else { range_ignore }, range_ignore
		}
		n := if last > size { size } else { last }
		return size - n, size - 1
	}
	if last >= 0 && last < first {
		return range_ignore, range_ignore
	}
	if first >= size {
		return range_unsatisfiable, range_unsatisfiable
	}
	end := if last < 0 || last >= size { size - 1 } else { last }
	return first, end
}

// range_num reads the digits at v[i..e]: their value (-1 when there are none) and
// the index after them. Past 18 digits the value is capped, which no file reaches.
fn range_num(v string, i int, e int) (i64, int) {
	mut k := i
	mut n := i64(0)
	for k < e && v[k] >= `0` && v[k] <= `9` {
		if n < 100_000_000_000_000_000 {
			n = n * 10 + i64(v[k] - `0`)
		}
		k++
	}
	return if k == i { i64(-1) } else { n }, k
}

struct MimeType {
	ext  string
	type string
}

const mime_types = [
	MimeType{'html', 'text/html; charset=utf-8'},
	MimeType{'htm', 'text/html; charset=utf-8'},
	MimeType{'css', 'text/css; charset=utf-8'},
	MimeType{'js', 'text/javascript; charset=utf-8'},
	MimeType{'mjs', 'text/javascript; charset=utf-8'},
	MimeType{'json', 'application/json'},
	MimeType{'map', 'application/json'},
	MimeType{'txt', 'text/plain; charset=utf-8'},
	MimeType{'md', 'text/markdown; charset=utf-8'},
	MimeType{'csv', 'text/csv; charset=utf-8'},
	MimeType{'xml', 'application/xml'},
	MimeType{'svg', 'image/svg+xml'},
	MimeType{'png', 'image/png'},
	MimeType{'jpg', 'image/jpeg'},
	MimeType{'jpeg', 'image/jpeg'},
	MimeType{'gif', 'image/gif'},
	MimeType{'webp', 'image/webp'},
	MimeType{'avif', 'image/avif'},
	MimeType{'ico', 'image/vnd.microsoft.icon'},
	MimeType{'woff', 'font/woff'},
	MimeType{'woff2', 'font/woff2'},
	MimeType{'ttf', 'font/ttf'},
	MimeType{'otf', 'font/otf'},
	MimeType{'wasm', 'application/wasm'},
	MimeType{'pdf', 'application/pdf'},
	MimeType{'zip', 'application/zip'},
	MimeType{'gz', 'application/gzip'},
	MimeType{'mp4', 'video/mp4'},
	MimeType{'webm', 'video/webm'},
	MimeType{'mp3', 'audio/mpeg'},
	MimeType{'ogg', 'audio/ogg'},
	MimeType{'wav', 'audio/wav'},
]

// content_type_for picks a Content-Type from name's extension; application/octet-stream
// when it has none or one not in the table.
pub fn content_type_for(name string) string {
	mut dot := -1
	for k := name.len - 1; k >= 0; k-- {
		if name[k] == `.` {
			dot = k
			break
		}
		if name[k] == `/` {
			break
		}
	}
	if dot >= 0 {
		ext := sub_view(name, dot + 1, name.len - dot - 1)
		for m in mime_types {
			if eq_fold(ext, m.ext) {
				return m.type
			}
		}
	}
	return 'application/octet-stream'
}

// sub_view is s[start..start + len] without a copy.
fn sub_view(s string, start int, len int) string {
	if len <= 0 {
		return ''
	}
	return unsafe { tos(s.str + start, len) }
}
