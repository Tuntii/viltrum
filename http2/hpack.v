module http2

// HPACK (RFC 7541), the header compression of HTTP/2. A Decoder turns the header
// blocks a peer sends into fields; an Encoder writes ours. Each keeps a dynamic table
// that the peer's side keeps in step with. Neither allocates: the table is a fixed
// ring inside it, and decoded names and values go into a buffer the caller sizes.

pub const default_table_size = 4096 // SETTINGS_HEADER_TABLE_SIZE's initial value, and the most we use

const entry_overhead = 32 // RFC 7541 4.1: an entry's size is its name and value plus 32
const max_entries = default_table_size / entry_overhead
const max_int = 1 << 28 // integers past this are refused (no length or index is that large)

// decode results
pub const hpack_ok = 0
pub const hpack_bad = -1 // a malformed block: a connection error (COMPRESSION_ERROR)
pub const hpack_too_large = -2 // the list passed the size or field limit; the table is still in step

pub const max_block_fields = 64 // the most fields a decoded block reports

// the static table (Appendix A); index 0 is unused
const static_names = ['', ':authority', ':method', ':method', ':path', ':path', ':scheme', ':scheme',
	':status', ':status', ':status', ':status', ':status', ':status', ':status', 'accept-charset',
	'accept-encoding', 'accept-language', 'accept-ranges', 'accept', 'access-control-allow-origin',
	'age', 'allow', 'authorization', 'cache-control', 'content-disposition', 'content-encoding',
	'content-language', 'content-length', 'content-location', 'content-range', 'content-type',
	'cookie', 'date', 'etag', 'expect', 'expires', 'from', 'host', 'if-match', 'if-modified-since',
	'if-none-match', 'if-range', 'if-unmodified-since', 'last-modified', 'link', 'location',
	'max-forwards', 'proxy-authenticate', 'proxy-authorization', 'range', 'referer', 'refresh',
	'retry-after', 'server', 'set-cookie', 'strict-transport-security', 'transfer-encoding',
	'user-agent', 'vary', 'via', 'www-authenticate']!
const static_values = ['', '', 'GET', 'POST', '/', '/index.html', 'http', 'https', '200', '204',
	'206', '304', '400', '404', '500', '', 'gzip, deflate', '', '', '', '', '', '', '', '', '',
	'', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
	'', '', '', '', '', '', '', '', '', '', '', '', '']!
const static_len = 61

// HField is one decoded field: where its name and value are in the decoder's output.
pub struct HField {
pub:
	name_off  int
	name_len  int
	value_off int
	value_len int
}

// Fields is a decoded header list.
pub struct Fields {
pub mut:
	f    [max_block_fields]HField
	n    int
	size int // the list's size as SETTINGS_MAX_HEADER_LIST_SIZE counts it: names, values, 32 a field
}

// Table is a dynamic table: entries newest first from index 1, their names and values
// in a ring of bytes. The bytes held never pass the size limit, so the ring has room.
struct Table {
mut:
	max   int = default_table_size // the size limit in force
	size  int // the entries' size, as RFC 7541 4.1 counts it
	bytes [default_table_size]u8
	wpos  int // where the next entry's bytes go
	// entries as a ring, the oldest at first
	off   [max_entries]u16
	nlen  [max_entries]u16
	vlen  [max_entries]u16
	first int
	count int
}

// slot is the ring position of entry i (1 is the newest).
@[inline]
fn (t &Table) slot(i int) int {
	return (t.first + t.count - i) % max_entries
}

fn (mut t Table) evict() {
	s := t.first
	t.size -= int(t.nlen[s]) + int(t.vlen[s]) + entry_overhead
	t.first = (t.first + 1) % max_entries
	t.count--
	if t.count == 0 {
		t.wpos = 0
	}
}

fn (mut t Table) set_max(n int) {
	t.max = n
	for t.size > t.max {
		t.evict()
	}
}

// add inserts name (ASCII-lowercased when fold is set) and value as the newest entry,
// evicting the oldest ones to make room. An entry larger than the limit empties the
// table and is not added (RFC 7541 4.4).
fn (mut t Table) add(name &u8, nlen int, value &u8, vlen int, fold bool) {
	need := nlen + vlen + entry_overhead
	if need > t.max {
		for t.count > 0 {
			t.evict()
		}
		return
	}
	for t.size + need > t.max {
		t.evict()
	}
	s := (t.first + t.count) % max_entries
	t.off[s] = u16(t.wpos)
	t.nlen[s] = u16(nlen)
	t.vlen[s] = u16(vlen)
	for k in 0 .. nlen {
		b := unsafe { name[k] }
		t.bytes[t.wpos] = if fold && b >= `A` && b <= `Z` { b + 32 } else { b }
		t.wpos = (t.wpos + 1) % default_table_size
	}
	for k in 0 .. vlen {
		t.bytes[t.wpos] = unsafe { value[k] }
		t.wpos = (t.wpos + 1) % default_table_size
	}
	t.count++
	t.size += need
}

// value_off is where the value of the entry in ring slot s starts.
@[inline]
fn (t &Table) value_off(s int) int {
	return (int(t.off[s]) + int(t.nlen[s])) % default_table_size
}

// copy_out appends n bytes of the ring from off to out.
fn (t &Table) copy_out(off int, n int, mut out []u8) {
	for k in 0 .. n {
		out << t.bytes[(off + k) % default_table_size]
	}
}

// ring_eq is whether n bytes of the ring from off equal s, ignoring ASCII case in s
// when fold is set (entry names are lowercase).
fn (t &Table) ring_eq(off int, n int, s string, fold bool) bool {
	if n != s.len {
		return false
	}
	for k in 0 .. n {
		mut b := s[k]
		if fold && b >= `A` && b <= `Z` {
			b += 32
		}
		if t.bytes[(off + k) % default_table_size] != b {
			return false
		}
	}
	return true
}

// read_int decodes the integer with an n-bit prefix at src[p] (RFC 7541 5.1): its
// value and the position after it, or a position of -1 when it is cut short or too large.
fn read_int(src []u8, p int, n int) (int, int) {
	mask := (1 << n) - 1
	mut v := int(src[p]) & mask
	mut i := p + 1
	if v < mask {
		return v, i
	}
	mut shift := 0
	for i < src.len && shift <= 21 {
		b := src[i]
		i++
		v += int(u32(b & 0x7f) << u32(shift))
		if v > max_int {
			break
		}
		if b & 0x80 == 0 {
			return v, i
		}
		shift += 7
	}
	return 0, -1
}

// write_int appends v with an n-bit prefix, the prefix byte's high bits from flags.
fn write_int(mut out []u8, flags u8, n int, v int) {
	mask := (1 << n) - 1
	if v < mask {
		out << flags | u8(v)
		return
	}
	out << flags | u8(mask)
	mut x := v - mask
	for x >= 128 {
		out << u8(x & 0x7f) | 0x80
		x >>= 7
	}
	out << u8(x)
}

// read_str decodes the string literal at src[p] (RFC 7541 5.2) onto out: the position
// after it, or -1 when it is cut short or its Huffman coding is invalid.
fn read_str(src []u8, p int, mut out []u8) int {
	if p >= src.len {
		return -1
	}
	huff := src[p] & 0x80 != 0
	n, q := read_int(src, p, 7)
	if q < 0 || n > src.len - q {
		return -1
	}
	if huff {
		if !huff_decode(src, q, q + n, mut out) {
			return -1
		}
	} else if n > 0 {
		unsafe { out.push_many(&u8(src.data) + q, n) }
	}
	return q + n
}

// write_str appends s as a literal without Huffman coding, lowercased when fold is set.
fn write_str(mut out []u8, s string, fold bool) {
	write_int(mut out, 0, 7, s.len)
	if !fold {
		unsafe { out.push_many(s.str, s.len) }
		return
	}
	for k in 0 .. s.len {
		b := s[k]
		out << if b >= `A` && b <= `Z` { b + 32 } else { b }
	}
}

// Decoder decodes the header blocks of one connection's peer.
pub struct Decoder {
mut:
	t     Table
	limit int = default_table_size // our SETTINGS_HEADER_TABLE_SIZE: the most a size update may ask for
}

// new_decoder is a Decoder for a connection whose SETTINGS_HEADER_TABLE_SIZE is
// table_size (at most default_table_size) from its first header block on.
pub fn new_decoder(table_size int) &Decoder {
	mut d := &Decoder{}
	d.limit = if table_size < default_table_size { table_size } else { default_table_size }
	d.t.max = d.limit
	return d
}

// name_of appends the name of table entry idx (static or dynamic) to out; false when
// there is no such entry.
fn (d &Decoder) name_of(idx int, mut out []u8) bool {
	if idx <= static_len {
		name := static_names[idx]
		unsafe { out.push_many(name.str, name.len) }
		return true
	}
	i := idx - static_len
	if i > d.t.count {
		return false
	}
	s := d.t.slot(i)
	d.t.copy_out(int(d.t.off[s]), int(d.t.nlen[s]), mut out)
	return true
}

// value_of appends the value of table entry idx to out (the entry exists).
fn (d &Decoder) value_of(idx int, mut out []u8) {
	if idx <= static_len {
		v := static_values[idx]
		if v.len > 0 {
			unsafe { out.push_many(v.str, v.len) }
		}
		return
	}
	s := d.t.slot(idx - static_len)
	d.t.copy_out(d.t.value_off(s), int(d.t.vlen[s]), mut out)
}

// decode decodes the header block src: names and values are appended to out and
// their positions put in fs. hpack_ok, hpack_bad, or hpack_too_large when the list
// passes max_size bytes (as fs.size counts) or max_block_fields fields: fs then holds
// the fields that fit, and the table is in step all the same, so the connection can
// go on.
pub fn (mut d Decoder) decode(src []u8, mut out []u8, mut fs Fields, max_size int) int {
	fs.n = 0
	fs.size = 0
	mut over := false
	mut fields_seen := false
	mut p := 0
	for p < src.len {
		b := src[p]
		if b & 0xe0 == 0x20 {
			// dynamic table size update: only before the first field (RFC 7541 4.2)
			v, q := read_int(src, p, 5)
			if q < 0 || fields_seen || v > d.limit {
				return hpack_bad
			}
			d.t.set_max(v)
			p = q
			continue
		}
		fields_seen = true
		mark := out.len
		mut name_len := 0
		if b & 0x80 != 0 {
			// indexed field
			idx, q := read_int(src, p, 7)
			if q < 0 || idx == 0 || !d.name_of(idx, mut out) {
				return hpack_bad
			}
			name_len = out.len - mark
			d.value_of(idx, mut out)
			p = q
		} else {
			// a literal: with incremental indexing (01), without (0000) or never (0001)
			n := if b & 0x40 != 0 { 6 } else { 4 }
			idx, q := read_int(src, p, n)
			if q < 0 {
				return hpack_bad
			}
			p = q
			if idx == 0 {
				p = read_str(src, p, mut out)
			} else if !d.name_of(idx, mut out) {
				p = -1
			}
			if p < 0 {
				return hpack_bad
			}
			name_len = out.len - mark
			p = read_str(src, p, mut out)
			if p < 0 {
				return hpack_bad
			}
			if n == 6 {
				base := unsafe { &u8(out.data) + mark }
				d.t.add(base, name_len, unsafe { base + name_len }, out.len - mark - name_len,
					false)
			}
		}
		value_len := out.len - mark - name_len
		size := name_len + value_len + entry_overhead
		if over || fs.n == max_block_fields || fs.size + size > max_size {
			// keep decoding so the table stays in step, but hold no more
			over = true
			unsafe {
				out.len = mark
			}
			continue
		}
		fs.f[fs.n] = HField{
			name_off:  mark
			name_len:  name_len
			value_off: mark + name_len
			value_len: value_len
		}
		fs.n++
		fs.size += size
	}
	return if over { hpack_too_large } else { hpack_ok }
}

// Index says whether an encoded field enters the dynamic tables.
pub enum Index {
	incremental // added to both tables, so a repeat is one byte
	without     // not added; for values that change with every response
	never       // not added, and intermediaries must not add it either (credentials)
}

// Encoder encodes the header blocks we send on one connection.
pub struct Encoder {
mut:
	t Table
	// size updates owed at the start of the next block (RFC 7541 4.2): the smallest
	// limit since the last block, then the one in force; -1 when none
	update_min int = -1
	update     int = -1
}

// new_encoder is an Encoder whose table holds table_size (at most
// default_table_size) from its first block on, with no size update owed.
pub fn new_encoder(table_size int) &Encoder {
	mut e := &Encoder{}
	e.t.max = if table_size < default_table_size { table_size } else { default_table_size }
	return e
}

// set_limit applies the peer's SETTINGS_HEADER_TABLE_SIZE. The table never grows
// past default_table_size.
pub fn (mut e Encoder) set_limit(n int) {
	m := if n < default_table_size { n } else { default_table_size }
	if m == e.t.max && e.update < 0 {
		return
	}
	e.t.set_max(m)
	if e.update_min < 0 || m < e.update_min {
		e.update_min = m
	}
	e.update = m
}

// begin starts a header block on out: the size updates owed, if any.
pub fn (mut e Encoder) begin(mut out []u8) {
	if e.update < 0 {
		return
	}
	if e.update_min < e.update {
		write_int(mut out, 0x20, 5, e.update_min)
	}
	write_int(mut out, 0x20, 5, e.update)
	e.update_min = -1
	e.update = -1
}

// field appends one field. name may be in any case; HTTP/2 sends it lowercase.
pub fn (mut e Encoder) field(mut out []u8, name string, value string, idx Index) {
	// a whole match in either table is one index
	mut name_idx := 0
	for i in 1 .. static_len + 1 {
		if eq_lower(name, static_names[i]) {
			if name_idx == 0 {
				name_idx = i
			}
			if static_values[i] == value && value.len > 0 {
				write_int(mut out, 0x80, 7, i)
				return
			}
		}
	}
	for i in 1 .. e.t.count + 1 {
		s := e.t.slot(i)
		if !e.t.ring_eq(int(e.t.off[s]), int(e.t.nlen[s]), name, true) {
			continue
		}
		if e.t.ring_eq(e.t.value_off(s), int(e.t.vlen[s]), value, false) {
			write_int(mut out, 0x80, 7, static_len + i)
			return
		}
		if name_idx == 0 {
			name_idx = static_len + i
		}
	}
	match idx {
		.incremental { write_int(mut out, 0x40, 6, name_idx) }
		.without { write_int(mut out, 0x00, 4, name_idx) }
		.never { write_int(mut out, 0x10, 4, name_idx) }
	}

	if name_idx == 0 {
		write_str(mut out, name, true)
	}
	write_str(mut out, value, false)
	if idx == .incremental {
		e.t.add(name.str, name.len, value.str, value.len, true)
	}
}

// eq_lower is whether s equals the lowercase name t, ignoring ASCII case in s.
fn eq_lower(s string, t string) bool {
	if s.len != t.len {
		return false
	}
	for k in 0 .. s.len {
		mut b := s[k]
		if b >= `A` && b <= `Z` {
			b += 32
		}
		if b != t[k] {
			return false
		}
	}
	return true
}
