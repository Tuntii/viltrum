module http1

// DEFLATE (RFC 1951) and gzip (RFC 1952), compression only, written for what a
// response body is: one buffer of a few KB, compressed in one call. That shape is
// where a general streaming compressor spends most of its time on things that do not
// apply: miniz clears ~97 KB of window and hash state per call and walks its input
// through a ring buffer, which made it ~half of json-comp's profile.
//
// Here the body is matched where it lies, in chunks of up to 64 KB, so positions fit
// in u16 and the hash table is sized to the chunk: a 6 KB body clears 16 KB. Matching
// is hash chains with one step of lazy evaluation; each chunk becomes one block, and
// the block type (dynamic, fixed or stored) is whichever costs the fewest bits.
// Everything the encoder needs is allocated once per worker in new_deflater, so
// compressing a response allocates nothing.

const window_size = 32768
const min_match = 4 // hashed on 4 bytes; 3-byte matches rarely pay for their codes
const max_match = 258
const max_chunk = 65534 // positions are stored + 1 in u16, 0 meaning none
const max_hash_bits = 15
// Search effort. json-comp scores rps / (bytes per response)^2; swept on the three
// /json shapes of the profile with the real dataset, these maximize it. Against depth
// 8 and inserts up to 16 they take a fifth off the time for 1.6% more bytes.
const search_depth = 4 // chain links tried per position
const nice_match = 32 // a match this long ends the search and the lazy step
const good_match = 8 // past this, the lazy step searches a quarter as deep
const max_insert = 4 // longer matches enter only their first position into the chains

const len_base = [u16(3), 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
	67, 83, 99, 115, 131, 163, 195, 227, 258]!
const len_xbits = [u8(0), 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
	5, 5, 5, 5, 0]!
const dist_base = [u16(1), 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513,
	769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]!
const dist_xbits = [u8(0), 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
	11, 11, 12, 12, 13, 13]!
// order in which code length code lengths are sent
const cl_order = [u8(16), 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]!

// len_sym maps a match length (3..258) to its length symbol minus 257.
const len_sym = make_len_sym()
// dist_sym_lo maps distance - 1 below 256 to its distance symbol, dist_sym_hi the
// rest by (distance - 1) >> 7; the ranges past 256 are 128-aligned.
const dist_sym_lo = make_dist_sym(false)
const dist_sym_hi = make_dist_sym(true)
const crc_table = make_crc_table()

fn make_len_sym() []u8 {
	mut t := []u8{len: max_match + 1}
	for s in 0 .. 28 {
		for l in int(len_base[s]) .. int(len_base[s]) + (1 << int(len_xbits[s])) {
			if l < max_match {
				t[l] = u8(s)
			}
		}
	}
	t[max_match] = 28
	return t
}

fn make_dist_sym(hi bool) []u8 {
	mut t := []u8{len: 256}
	for s in 0 .. 30 {
		for d in int(dist_base[s]) - 1 .. int(dist_base[s]) - 1 + (1 << int(dist_xbits[s])) {
			if !hi && d < 256 {
				t[d] = u8(s)
			} else if hi && d >= 256 {
				t[d >> 7] = u8(s)
			}
		}
	}
	return t
}

// make_crc_table builds the eight tables of slice-by-8 CRC-32 (IEEE, reflected).
fn make_crc_table() []u32 {
	mut t := []u32{len: 8 * 256}
	for i in 0 .. 256 {
		mut c := u32(i)
		for _ in 0 .. 8 {
			c = if c & 1 != 0 { (c >> 1) ^ 0xedb88320 } else { c >> 1 }
		}
		t[i] = c
	}
	for i in 0 .. 256 {
		for k in 1 .. 8 {
			prev := t[(k - 1) * 256 + i]
			t[k * 256 + i] = (prev >> 8) ^ t[prev & 0xff]
		}
	}
	return t
}

@[heap]
pub struct Deflater {
mut:
	head &u16 = unsafe { nil } // hash -> latest position + 1
	prev &u16 = unsafe { nil } // position -> earlier position + 1 with the same hash
	seq  &u32 = unsafe { nil } // the chunk: a literal byte, or 1 << 31 | dist sym << 25 | len << 16 | dist
	out  []u8
	w    BitWriter
	// per chunk
	lit_freq  [286]u32
	dist_freq [30]u32
	lit_len   [288]u8
	dist_len  [32]u8
	lit_code  [288]u16
	dist_code [32]u16
	all_len   [320]u8 // literal/length and distance lengths, as the header sends them
	cl_freq   [19]u32
	cl_len    [19]u8
	cl_code   [19]u16
	rle       [320]u16 // code length symbols, extra value << 5 | symbol
	nrle      int
	// Huffman scratch
	keys [288]u32
}

pub fn new_deflater() &Deflater {
	return unsafe {
		&Deflater{
			head: &u16(malloc_noscan((1 << max_hash_bits) * 2))
			prev: &u16(malloc_noscan((max_chunk + 1) * 2))
			seq:  &u32(malloc_noscan(max_chunk * 4))
			out:  []u8{cap: 16 * 1024}
		}
	}
}

// gzip compresses src into one gzip member. The result is a view of the deflater's
// buffer, valid until the next call.
pub fn (mut d Deflater) gzip(src []u8) ![]u8 {
	// stored blocks bound the output: 5 bytes per chunk over the input, plus framing
	bound := 10 + src.len + 5 * (src.len / max_chunk + 1) + 8 + 16
	if d.out.cap < bound {
		d.out = []u8{cap: bound + bound / 4}
	}
	unsafe {
		mut p := &u8(d.out.data)
		p[0] = 0x1f
		p[1] = 0x8b
		p[2] = 8 // CM = deflate
		for k in 3 .. 9 {
			p[k] = 0 // FLG, MTIME (4), XFL
		}
		p[9] = 0xff // OS unknown
		d.w = BitWriter{
			op: p + 10
		}
	}
	mut at := 0
	for {
		n := if src.len - at > max_chunk { max_chunk } else { src.len - at }
		last := at + n == src.len
		d.chunk(unsafe { &u8(src.data) + at }, n, last)
		at += n
		if last {
			break
		}
	}
	_ = d.w.flush()
	crc := crc32(src.data, src.len)
	size := u32(src.len)
	unsafe {
		mut p := d.w.op
		for k in 0 .. 4 {
			p[k] = u8(crc >> (8 * k))
			p[4 + k] = u8(size >> (8 * k))
		}
		d.out.len = int(p + 8 - &u8(d.out.data))
	}
	return view(d.out, 0, d.out.len)
}

// load32 and load64 read unaligned words in native order, for hashing and equality.
@[inline]
fn load32(p &u8) u32 {
	mut v := u32(0)
	unsafe { C.memcpy(&v, p, 4) }
	return v
}

@[inline]
fn load64(p &u8) u64 {
	mut v := u64(0)
	unsafe { C.memcpy(&v, p, 8) }
	return v
}

@[inline]
fn dist_sym(dist int) int {
	return if dist <= 256 { dist_sym_lo[dist - 1] } else { dist_sym_hi[(dist - 1) >> 7] }
}

// chunk matches n bytes at src and writes them as one block. The tables are read
// through locals: V builds with -fno-strict-aliasing, so through d every byte or u16
// store would reload them.
@[direct_array_access]
fn (mut d Deflater) chunk(src &u8, n int, last bool) {
	head := d.head
	prev := d.prev
	seq := d.seq
	mut lf := &d.lit_freq[0]
	mut df := &d.dist_freq[0]
	mut hb := 10
	for hb < max_hash_bits && (1 << hb) < n {
		hb++
	}
	unsafe { vmemset(head, 0, (1 << hb) * 2) }
	shift := 32 - hb
	unsafe {
		vmemset(lf, 0, 286 * 4)
		vmemset(df, 0, 30 * 4)
	}
	mut ns := 0
	mut ins := 0 // next position to enter into the hash chains
	limit := n - min_match // last position with 4 bytes to hash
	mut i := 0
	for i < n {
		if i > limit {
			c := unsafe { src[i] }
			unsafe {
				lf[c]++
				seq[ns] = c
			}
			ns++
			i++
			continue
		}
		for ins < i {
			insert(head, prev, src, ins, shift)
			ins++
		}
		mut len, mut dist := find(head, prev, src, n, i, shift, search_depth)
		ins = i + 1
		if len < min_match {
			c := unsafe { src[i] }
			unsafe {
				lf[c]++
				seq[ns] = c
			}
			ns++
			i++
			continue
		}
		// lazy step: a longer match one byte on is worth a literal now
		for len < nice_match && i + 1 <= limit {
			len2, dist2 := find(head, prev, src, n, i + 1, shift, if len >= good_match {
				search_depth / 4
			} else {
				search_depth
			})
			ins = i + 2
			if len2 <= len {
				break
			}
			c := unsafe { src[i] }
			unsafe {
				lf[c]++
				seq[ns] = c
			}
			ns++
			i++
			len = len2
			dist = dist2
		}
		ds := dist_sym(dist)
		unsafe {
			lf[257 + len_sym[len]]++
			df[ds]++
			seq[ns] = u32(1) << 31 | u32(ds) << 25 | u32(len) << 16 | u32(dist)
		}
		ns++
		i += len
		if len > max_insert {
			ins = i
		}
	}
	d.lit_freq[256] = 1
	d.block(src, n, ns, last)
}

@[inline]
fn insert(head &u16, prev &u16, src &u8, i int, shift int) {
	h := (unsafe { load32(src + i) } * 0x1e35a7bd) >> shift
	unsafe {
		prev[i] = head[h]
		head[h] = u16(i + 1)
	}
}

// find returns the longest earlier match for position i, (0, 0) when none reaches
// min_match, and enters i into the chains.
@[direct_array_access; inline]
fn find(head &u16, prev &u16, src &u8, n int, i int, shift int, depth_max int) (int, int) {
	h := (unsafe { load32(src + i) } * 0x1e35a7bd) >> shift
	mut cand := 0
	unsafe {
		cand = int(head[h])
		prev[i] = u16(cand)
		head[h] = u16(i + 1)
	}
	max_len := if n - i < max_match { n - i } else { max_match }
	cur := unsafe { src + i }
	first := load32(cur)
	mut best := min_match - 1
	mut best_dist := 0
	mut depth := depth_max
	for cand > 0 && depth > 0 {
		c := cand - 1
		dist := i - c
		if dist > window_size {
			break
		}
		m := unsafe { src + c }
		if unsafe { m[best] == cur[best] } && load32(m) == first {
			mut l := 4
			for l + 8 <= max_len && unsafe { load64(m + l) == load64(cur + l) } {
				l += 8
			}
			for l < max_len && unsafe { m[l] == cur[l] } {
				l++
			}
			if l > best {
				best = l
				best_dist = dist
				if l >= nice_match || l >= max_len {
					break
				}
			}
		}
		cand = int(unsafe { prev[c] })
		depth--
	}
	if best < min_match {
		return 0, 0
	}
	return best, best_dist
}

// block writes the chunk's sequences as one block of whichever type is smallest.
@[direct_array_access]
fn (mut d Deflater) block(src &u8, n int, ns int, last bool) {
	huff_lengths(mut d.keys, &d.lit_freq[0], 286, 15, &d.lit_len[0])
	huff_lengths(mut d.keys, &d.dist_freq[0], 30, 15, &d.dist_len[0])
	mut hlit := 286
	for hlit > 257 && d.lit_len[hlit - 1] == 0 {
		hlit--
	}
	mut hdist := 30
	for hdist > 1 && d.dist_len[hdist - 1] == 0 {
		hdist--
	}
	for k in 0 .. hlit {
		d.all_len[k] = d.lit_len[k]
	}
	for k in 0 .. hdist {
		d.all_len[hlit + k] = d.dist_len[k]
	}
	d.rle_lengths(hlit + hdist)
	for k in 0 .. 19 {
		d.cl_freq[k] = 0
	}
	for k in 0 .. d.nrle {
		d.cl_freq[d.rle[k] & 31]++
	}
	huff_lengths(mut d.keys, &d.cl_freq[0], 19, 7, &d.cl_len[0])
	mut hclen := 19
	for hclen > 4 && d.cl_len[cl_order[hclen - 1]] == 0 {
		hclen--
	}

	// cost in bits of each block type; extra bits are common to dynamic and fixed
	mut extra := u64(0)
	for s in 0 .. 29 {
		extra += u64(d.lit_freq[257 + s]) * len_xbits[s]
	}
	for s in 0 .. 30 {
		extra += u64(d.dist_freq[s]) * dist_xbits[s]
	}
	mut dyn := u64(3 + 14 + 3 * hclen) + extra
	for k in 0 .. d.nrle {
		sym := d.rle[k] & 31
		dyn += d.cl_len[sym]
		dyn += match sym {
			16 { u64(2) }
			17 { u64(3) }
			18 { u64(7) }
			else { u64(0) }
		}
	}
	mut fixed := u64(3) + extra
	for s in 0 .. 286 {
		f := u64(d.lit_freq[s])
		dyn += f * d.lit_len[s]
		fixed += f * fixed_lit_len(s)
	}
	for s in 0 .. 30 {
		dyn += u64(d.dist_freq[s]) * d.dist_len[s]
		fixed += u64(d.dist_freq[s]) * 5
	}
	stored := u64(3 + 7 + 32) + u64(n) * 8

	bfinal := if last { u32(1) } else { u32(0) }
	// Written through a local copy, which stays in registers. With a struct in scope
	// every call is written `_ = f()`, which V 0.5.2 does not pin (see jsonenc).
	mut w := d.w
	if stored <= dyn && stored <= fixed {
		_ = w.put(bfinal, 3) // BTYPE 00
		_ = w.flush()
		unsafe {
			mut p := w.op
			p[0] = u8(n)
			p[1] = u8(n >> 8)
			p[2] = u8(~n)
			p[3] = u8(~n >> 8)
			_ = vmemcpy(p + 4, src, n)
			w.op = p + 4 + n
		}
		d.w = w
		return
	}
	if fixed <= dyn {
		for s in 0 .. 288 {
			d.lit_len[s] = fixed_lit_len(s)
		}
		for s in 0 .. 30 {
			d.dist_len[s] = 5
		}
		_ = canonical(&d.lit_len[0], 288, &d.lit_code[0])
		_ = canonical(&d.dist_len[0], 30, &d.dist_code[0])
		_ = w.put(bfinal | 1 << 1, 3)
	} else {
		_ = canonical(&d.lit_len[0], 286, &d.lit_code[0])
		_ = canonical(&d.dist_len[0], 30, &d.dist_code[0])
		_ = canonical(&d.cl_len[0], 19, &d.cl_code[0])
		_ = w.put(bfinal | 2 << 1, 3)
		_ = w.put(u32(hlit - 257) | u32(hdist - 1) << 5 | u32(hclen - 4) << 10, 14)
		for k in 0 .. hclen {
			_ = w.put(d.cl_len[cl_order[k]], 3)
		}
		for k in 0 .. d.nrle {
			r := d.rle[k]
			sym := r & 31
			xv := u32(r >> 5)
			_ = w.put(d.cl_code[sym], d.cl_len[sym])
			match sym {
				16 { _ = w.put(xv, 2) }
				17 { _ = w.put(xv, 3) }
				18 { _ = w.put(xv, 7) }
				else {}
			}
		}
	}
	for k in 0 .. ns {
		e := unsafe { d.seq[k] }
		if e >> 31 == 0 {
			_ = w.put(d.lit_code[e], d.lit_len[e])
			continue
		}
		len := int((e >> 16) & 0x1ff)
		ls := len_sym[len]
		lbits := d.lit_len[257 + ls]
		_ = w.put(u32(d.lit_code[257 + ls]) | u32(len - int(len_base[ls])) << lbits, lbits +
			len_xbits[ls])
		dist := int(e & 0xffff)
		ds := int((e >> 25) & 31)
		dbits := d.dist_len[ds]
		_ = w.put(u32(d.dist_code[ds]) | u32(dist - int(dist_base[ds])) << dbits, dbits +
			dist_xbits[ds])
	}
	_ = w.put(d.lit_code[256], d.lit_len[256])
	d.w = w
}

@[inline]
fn fixed_lit_len(s int) u8 {
	return if s < 144 {
		u8(8)
	} else if s < 256 {
		9
	} else if s < 280 {
		7
	} else {
		8
	}
}

// rle_lengths run-length codes all_len[..n] into code length symbols 0-18.
@[direct_array_access]
fn (mut d Deflater) rle_lengths(n int) {
	d.nrle = 0
	mut i := 0
	for i < n {
		l := d.all_len[i]
		mut run := 1
		for i + run < n && d.all_len[i + run] == l {
			run++
		}
		i += run
		if l == 0 {
			for run >= 11 {
				r := if run > 138 { 138 } else { run }
				d.rle[d.nrle] = u16(18) | u16(r - 11) << 5
				d.nrle++
				run -= r
			}
			if run >= 3 {
				d.rle[d.nrle] = u16(17) | u16(run - 3) << 5
				d.nrle++
				run = 0
			}
		} else {
			d.rle[d.nrle] = l
			d.nrle++
			run--
			for run >= 3 {
				r := if run > 6 { 6 } else { run }
				d.rle[d.nrle] = u16(16) | u16(r - 3) << 5
				d.nrle++
				run -= r
			}
		}
		for run > 0 {
			d.rle[d.nrle] = l
			d.nrle++
			run--
		}
	}
}

struct BitWriter {
mut:
	op  &u8 = unsafe { nil } // next byte of output
	buf u64 // bits not yet written, LSB first
	cnt int
}

// put appends the low n bits of v (n <= 32), LSB first.
@[inline]
fn (mut w BitWriter) put(v u32, n int) bool {
	w.buf |= u64(v) << w.cnt
	w.cnt += n
	if w.cnt >= 32 {
		unsafe {
			mut p := w.op
			p[0] = u8(w.buf)
			p[1] = u8(w.buf >> 8)
			p[2] = u8(w.buf >> 16)
			p[3] = u8(w.buf >> 24)
			w.op = p + 4
		}
		w.buf >>= 32
		w.cnt -= 32
	}
	return true
}

// flush writes the pending bits, zero-padded to a byte boundary.
fn (mut w BitWriter) flush() bool {
	unsafe {
		mut p := w.op
		for w.cnt > 0 {
			*p = u8(w.buf)
			p++
			w.buf >>= 8
			w.cnt -= 8
		}
		w.op = p
	}
	w.buf = 0
	w.cnt = 0
	return true
}

// huff_lengths sets lens[..n] to Huffman code lengths of at most max_bits for freq.
// The tree is built in place over the used symbols sorted by frequency (Moffat and
// Katajainen), then lengths over max_bits are folded back the way zlib does. A code
// always gets at least two symbols, as decoders expect a complete code.
@[direct_array_access]
fn huff_lengths(mut keys [288]u32, freq &u32, n int, max_bits int, lens &u8) {
	mut m := 0
	for s in 0 .. n {
		unsafe {
			lens[s] = 0
		}
		f := unsafe { freq[s] }
		if f != 0 {
			// frequency above the symbol: sorting the keys sorts by (freq, sym)
			keys[m] = f << 9 | u32(s)
			m++
		}
	}
	if m < 2 {
		// one or no symbol: two codes of length 1, the used one and another
		used := if m == 1 { int(keys[0] & 0x1ff) } else { 0 }
		other := if used == 0 { 1 } else { 0 }
		unsafe {
			lens[used] = 1
			lens[other] = 1
		}
		return
	}
	sort_keys(mut keys, m)
	// a holds weights, then parent links, then depths (Moffat-Katajainen)
	mut a := [288]u32{}
	for k in 0 .. m {
		a[k] = keys[k] >> 9
	}
	a[0] += a[1]
	mut root := 0
	mut leaf := 2
	for next in 1 .. m - 1 {
		if leaf >= m || a[root] < a[leaf] {
			a[next] = a[root]
			a[root] = u32(next)
			root++
		} else {
			a[next] = a[leaf]
			leaf++
		}
		if leaf >= m || (root < next && a[root] < a[leaf]) {
			a[next] += a[root]
			a[root] = u32(next)
			root++
		} else {
			a[next] += a[leaf]
			leaf++
		}
	}
	a[m - 2] = 0
	for next := m - 3; next >= 0; next-- {
		a[next] = a[a[next]] + 1
	}
	mut avail := 1
	mut used := 0
	mut depth := u32(0)
	mut rt := m - 2
	mut nx := m - 1
	for avail > 0 {
		for rt >= 0 && a[rt] == depth {
			used++
			rt--
		}
		for avail > used {
			a[nx] = depth
			nx--
			avail--
		}
		avail = 2 * used
		depth++
		used = 0
	}
	// a[k] is now the length of keys[k]; count per length, folding overlong ones
	mut count := [16]int{}
	mut overflow := 0
	for k in 0 .. m {
		mut l := int(a[k])
		if l > max_bits {
			l = max_bits
			overflow++
		}
		count[l]++
	}
	for overflow > 0 {
		mut b := max_bits - 1
		for count[b] == 0 {
			b--
		}
		count[b]--
		count[b + 1] += 2
		count[max_bits]--
		overflow -= 2
	}
	// least frequent symbols take the longest lengths
	mut k := 0
	for l := max_bits; l >= 1; l-- {
		for _ in 0 .. count[l] {
			unsafe {
				lens[keys[k] & 0x1ff] = u8(l)
			}
			k++
		}
	}
}

// sort_keys sorts keys[..m] ascending. The keys are distinct (the symbol is in the low
// bits), so any correct sort gives the same order. Insertion sort was a fifth of a
// JSON page's block: a literal alphabet uses about 80 symbols. Past a few dozen keys
// this is an LSD radix sort, a byte per pass, as many passes as the largest key needs.
@[direct_array_access]
fn sort_keys(mut keys [288]u32, m int) {
	if m <= 24 {
		for k in 1 .. m {
			v := keys[k]
			mut j := k
			for j > 0 && keys[j - 1] > v {
				keys[j] = keys[j - 1]
				j--
			}
			keys[j] = v
		}
		return
	}
	mut top := u32(0)
	for k in 0 .. m {
		top |= keys[k]
	}
	mut tmp := [288]u32{}
	mut shift := u32(0)
	for shift < 32 && (top >> shift) != 0 {
		mut count := [257]int{}
		for k in 0 .. m {
			count[((keys[k] >> shift) & 0xff) + 1]++
		}
		for b in 1 .. 257 {
			count[b] += count[b - 1]
		}
		for k in 0 .. m {
			b := (keys[k] >> shift) & 0xff
			tmp[count[b]] = keys[k]
			count[b]++
		}
		for k in 0 .. m {
			keys[k] = tmp[k]
		}
		shift += 8
	}
}

const rev8 = make_rev8()

fn make_rev8() [256]u8 {
	mut t := [256]u8{}
	for v in 0 .. 256 {
		mut r := 0
		for b in 0 .. 8 {
			r |= ((v >> b) & 1) << (7 - b)
		}
		t[v] = u8(r)
	}
	return t
}

// canonical assigns the canonical codes of RFC 1951 3.2.2 for lens, bit-reversed
// for LSB-first output.
@[direct_array_access]
fn canonical(lens &u8, n int, codes &u16) bool {
	mut count := [16]u16{}
	for s in 0 .. n {
		count[unsafe { lens[s] }]++
	}
	count[0] = 0
	mut next := [16]u16{}
	mut code := u16(0)
	for b in 1 .. 16 {
		code = (code + count[b - 1]) << 1
		next[b] = code
	}
	for s in 0 .. n {
		l := unsafe { lens[s] }
		if l == 0 {
			continue
		}
		c := next[l]
		next[l]++
		// the l-bit code reversed: both bytes reversed and swapped, then shifted down
		r := (u16(rev8[c & 0xff]) << 8 | u16(rev8[c >> 8])) >> (16 - l)
		unsafe {
			codes[s] = r
		}
	}
	return true
}

#include "@VMODROOT/http1/crc32_clmul.h"

fn C.viltrum_have_clmul() int
fn C.viltrum_crc32_clmul(crc u32, p &u8, n usize) u32

// have_clmul is whether this CPU (and compiler) can run crc32_clmul.h.
const have_clmul = C.viltrum_have_clmul() != 0

// crc32 is CRC-32 (IEEE) over n bytes at p: by carry-less multiplication over the
// 16-byte blocks where the CPU has it (about 0.1 ns a byte against 0.7), then eight
// bytes per step from a table.
@[direct_array_access]
fn crc32(p &u8, n int) u32 {
	mut c := u32(0xffffffff)
	mut i := 0
	if have_clmul && n >= 64 {
		i = n & ~15
		c = C.viltrum_crc32_clmul(c, p, usize(i))
	}
	for i + 8 <= n {
		lo := unsafe { u32(p[i]) | u32(p[i + 1]) << 8 | u32(p[i + 2]) << 16 | u32(p[i + 3]) << 24 } ^ c
		hi := unsafe { u32(p[i + 4]) | u32(p[i + 5]) << 8 | u32(p[i + 6]) << 16 | u32(p[i + 7]) << 24 }
		c = crc_table[7 * 256 + (lo & 0xff)] ^ crc_table[6 * 256 + ((lo >> 8) & 0xff)] ^ crc_table[
			5 * 256 + ((lo >> 16) & 0xff)] ^ crc_table[4 * 256 + (lo >> 24)] ^ crc_table[3 * 256 +
			(hi & 0xff)] ^ crc_table[2 * 256 + ((hi >> 8) & 0xff)] ^ crc_table[256 +
			((hi >> 16) & 0xff)] ^ crc_table[hi >> 24]
		i += 8
	}
	for i < n {
		c = crc_table[(c ^ unsafe { p[i] }) & 0xff] ^ (c >> 8)
		i++
	}
	return ~c
}
