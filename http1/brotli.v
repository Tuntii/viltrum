module http1

import math.bits

// A Brotli (RFC 7932) encoder on the DEFLATE matcher's hash chains and output buffer
// (deflate.v), for the clients that accept br. What it uses of the format: one
// meta-block per chunk of up to br_chunk bytes; one block type for each category;
// literals coded with four prefix codes chosen by the byte before (UTF8 context mode,
// its 64 contexts folded into four classes: letters, digits and separators, quotes and
// brackets, the rest); the four last distances, which JSON's repeated keys hit all the
// time. No static dictionary and no block splitting.

const br_chunk = 65520 // a meta-block's bytes: the WBITS 16 window, so every distance fits
// the literal tree of each class of the byte before (see make_br_tree_of): the rest,
// quotes and brackets, digits and separators, letters
const br_class_tree = [u8(0), 1, 2, 3]!
const br_trees = 4
const br_depth = search_depth // hash chain links tried per position
const br_lazy = true
const br_nice = 32 // a match this long ends the search and the lazy step
const br_lazy_gain = 175 // what the next position's match must beat by, in score units

// insert and copy lengths (RFC 7932 5): base and extra bits per code
const br_ins_base = [u32(0), 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322,
	578, 1090, 2114, 6210, 22594]!
const br_ins_xbits = [u8(0), 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14,
	24]!
const br_cpy_base = [u32(2), 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134,
	198, 326, 582, 1094, 2118]!
const br_cpy_xbits = [u8(0), 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24]!

// the first insert-and-copy symbol of each (insert code >> 3, copy code >> 3) cell
// with an explicit distance (RFC 7932 5)
const br_cells = [u16(128), 192, 384, 256, 320, 512, 448, 576, 640]!

// code length code lengths: their order in the header and their fixed code
const br_cl_order = [u8(1), 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]!
const br_cl_sym = [u8(0), 7, 3, 2, 1, 15]!
const br_cl_bits = [u8(2), 4, 3, 2, 2, 4]!

// br_tree_of is the literal tree for the byte before: RFC 7932's UTF8 context Lut0
// shifted down by four (Lut1, of the byte before that, never reaches those bits).
const br_tree_of = make_br_tree_of()

// br_cmap is the literal context map (context >> 4) as its header bits, value << 8 |
// count, coded once.
const br_cmap = make_br_cmap()

struct BrState {
mut:
	lit_freq  [1024]u32 // br_trees x 256
	iac_freq  [704]u32
	dist_freq [64]u32
	lit_len   [1024]u8
	lit_code  [1024]u16
	iac_len   [704]u8
	iac_code  [704]u16
	dist_len  [64]u8
	dist_code [64]u16
	rle       [704]u16 // code length symbols, extra << 5 | symbol
	nrle_cl   int
	ncmd      int // command words br_parse left in Deflater.seq
	cl_freq   [18]u32
	cl_len    [18]u8
	cl_code   [18]u16
	ring      [4]int // the last four distances, last first
}

fn make_br_tree_of() [256]u8 {
	mut t := [256]u8{}
	for c in 0 .. 256 {
		class := match u8(c) {
			`a`...`z`, `A`...`Z` { 3 }
			`0`...`9`, `,`, `.`, `:`, `;`, `=` { 2 }
			`"`, `'`, `%`, `(`, `)`, `<`, `>`, `[`, `]`, `{`, `}` { 1 }
			else { 0 }
		}
		t[c] = br_class_tree[class]
	}
	return t
}

// make_br_cmap codes the context map: contexts 16k..16k+15 to the tree of class k,
// move-to-front then runs of zeros (RLEMAX 4), under a prefix code of its own.
fn make_br_cmap() []u32 {
	if br_trees == 1 {
		return []u32{}
	}
	mut mtf := [u8(0), 1, 2, 3]!
	mut vals := []u8{}
	for ctx in 0 .. 64 {
		v := br_class_tree[ctx >> 4]
		mut k := 0
		for mtf[k] != v {
			k++
		}
		for j := k; j > 0; j-- {
			mtf[j] = mtf[j - 1]
		}
		mtf[0] = v
		vals << u8(k)
	}
	rlemax := 4
	mut syms := []u32{} // symbol | extra << 8
	mut i := 0
	for i < vals.len {
		if vals[i] != 0 {
			syms << u32(vals[i]) + u32(rlemax)
			i++
			continue
		}
		mut run := 0
		for i + run < vals.len && vals[i + run] == 0 {
			run++
		}
		i += run
		for run > 0 {
			mut r := 0
			for r < rlemax && (2 << r) <= run {
				r++
			}
			if r == 0 {
				syms << 0
				run--
				continue
			}
			take := if run < (2 << r) - 1 { run } else { (2 << r) - 1 }
			syms << u32(r) | u32(take - (1 << r)) << 8
			run -= take
		}
	}
	// written with br_prefix into a scratch buffer, then kept as bytes to replay
	mut freq := [8]u32{}
	for s in syms {
		freq[s & 0xff]++
	}
	mut lens := [8]u8{}
	mut codes := [8]u16{}
	mut t := &Deflater{}
	buf := []u8{len: 512}
	t.w = BitWriter{
		op: unsafe { &u8(buf.data) }
	}
	_ = t.w.put(1, 1) // RLEMAX present
	_ = t.w.put(u32(rlemax - 1), 4)
	_ = t.br_prefix(&freq[0], br_trees + rlemax, if br_trees + rlemax > 4 { 3 } else { 2 }, &lens[0],
		&codes[0])
	for s in syms {
		sym := s & 0xff
		_ = t.w.put(codes[sym], lens[sym])
		if sym >= 1 && sym <= u32(rlemax) {
			_ = t.w.put(s >> 8, int(sym))
		}
	}
	_ = t.w.put(1, 1) // IMTF
	nbits := int(unsafe { t.w.op - &u8(buf.data) }) * 8 + t.w.cnt
	_ = t.w.flush()
	mut out := []u32{}
	for k in 0 .. nbits / 8 {
		out << u32(buf[k]) << 8 | 8
	}
	if nbits % 8 != 0 {
		out << u32(buf[nbits / 8]) << 8 | u32(nbits % 8)
	}
	return out
}

// brotli compresses src into a Brotli stream. The result is a view of the deflater's
// buffer, valid until the next call.
pub fn (mut d Deflater) brotli(src []u8) ![]u8 {
	// a chunk's compressed attempt may run past its input (a command costs at most
	// about 11 bytes and copies at least 2) before it falls back to a stored
	// meta-block; stored ones cost 4 bytes of header and padding each
	chunk_max := if src.len < br_chunk { src.len } else { br_chunk }
	bound := src.len + 8 * (src.len / br_chunk + 1) + 6 * chunk_max + 4096
	if d.out.cap < bound {
		d.out = []u8{cap: bound + bound / 4} // cold: grows once per worker
	}
	d.w = BitWriter{
		op: unsafe { &u8(d.out.data) }
	}
	_ = d.w.put(0, 1) // WBITS 16
	d.br.ring = [4, 11, 15, 16]!
	mut need_last := true
	if src.len > 0 {
		mut at := 0
		for at < src.len {
			n := if src.len - at > br_chunk { br_chunk } else { src.len - at }
			last := at + n == src.len
			stored := d.br_chunk(&u8(src.data), at, n, last)
			at += n
			if last && !stored {
				need_last = false
			}
		}
	}
	if need_last {
		_ = d.w.put(3, 2) // ISLAST, ISLASTEMPTY
	}
	_ = d.w.flush()
	unsafe {
		d.out.len = int(d.w.op - &u8(d.out.data))
	}
	return view(d.out, 0, d.out.len)
}

// br_score is how much a match is worth, from the reference encoder's heuristic:
// every byte copied gains, a far distance costs its bits, a cached one costs none.
@[inline]
fn br_score(len int, dist int, cached bool) int {
	if cached {
		return 135 * len + 1935
	}
	return 1920 + 135 * len - 30 * (31 - bits.leading_zeros_32(u32(dist)))
}

// br_match_len extends a match of from bytes at m and cur up to lim.
@[direct_array_access; inline]
fn br_match_len(m &u8, cur &u8, from int, lim int) int {
	mut l := from
	for l + 8 <= lim && unsafe { load64(m + l) == load64(cur + l) } {
		l += 8
	}
	for l < lim && unsafe { m[l] == cur[l] } {
		l++
	}
	return l
}

// br_find is find (deflate.v) for brotli: the last distances first (the last one from
// two bytes, the others from four), then depth links of the hash chain, keeping the
// match with the best score. Lengths are measured up to br_nice, and only the winner
// past it. Enters i into the chains. Returns (len, dist, score), len 0 when nothing pays.
@[direct_array_access; inline]
fn br_find(head &u16, prev &u16, src &u8, n int, i int, shift int, ring &int, depth_max int) (int, int, int) {
	max_len := n - i
	if max_len < 2 {
		return 0, 0, 0
	}
	cur := unsafe { src + i }
	lim := if max_len < br_nice { max_len } else { br_nice }
	mut best := 0
	mut best_dist := 0
	mut best_score := 0
	mut best_cached := false
	r0 := unsafe { ring[0] }
	if r0 <= i {
		m := unsafe { src + i - r0 }
		if unsafe { m[0] == cur[0] && m[1] == cur[1] } {
			best = br_match_len(m, cur, 2, lim)
			best_dist = r0
			best_score = br_score(best, r0, true)
			best_cached = true
		}
	}
	if max_len < min_match {
		return best, best_dist, best_score
	}
	first := load32(cur)
	for k in 1 .. 4 {
		dist := unsafe { ring[k] }
		if dist > i || load32(unsafe { src + i - dist }) != first {
			continue
		}
		l := br_match_len(unsafe { src + i - dist }, cur, 4, lim)
		s := br_score(l, dist, true)
		if s > best_score {
			best = l
			best_dist = dist
			best_score = s
			best_cached = true
		}
	}
	h := (first * 0x1e35a7bd) >> shift
	mut cand := 0
	unsafe {
		cand = int(head[h])
		prev[i] = u16(cand)
		head[h] = u16(i + 1)
	}
	mut depth := depth_max
	for best < lim && cand > 0 && depth > 0 {
		c := cand - 1
		m := unsafe { src + c }
		// only a longer match can win here: equal-length cached ones were tried above
		if unsafe { m[best] == cur[best] } && load32(m) == first {
			dist := i - c
			l := br_match_len(m, cur, 4, lim)
			cached := dist == r0 || dist == unsafe { ring[1] } || dist == unsafe { ring[2] }
				|| dist == unsafe { ring[3] }
			s := br_score(l, dist, cached)
			if s > best_score {
				best = l
				best_dist = dist
				best_score = s
				best_cached = cached
			}
		}
		cand = int(unsafe { prev[c] })
		depth--
	}
	if best == lim && lim < max_len {
		best = br_match_len(unsafe { src + i - best_dist }, cur, lim, max_len)
		best_score = br_score(best, best_dist, best_cached)
	}
	return best, best_dist, best_score
}

// br_dist_code is the distance code for dist given the last four distances, with
// its extra bits value (RFC 7932 4; NPOSTFIX and NDIRECT 0).
@[inline]
fn br_dist_code(dist int, ring &int) (int, u32) {
	r0 := unsafe { ring[0] }
	r1 := unsafe { ring[1] }
	if dist == r0 {
		return 0, 0
	}
	if dist == r1 {
		return 1, 0
	}
	o0 := u32(dist + 3 - r0)
	if o0 < 7 {
		return int((u32(0x9750468) >> (4 * o0)) & 0xf), 0
	}
	o1 := u32(dist + 3 - r1)
	if o1 < 7 {
		return int((u32(0xfdb1ace) >> (4 * o1)) & 0xf), 0
	}
	if dist == unsafe { ring[2] } {
		return 2, 0
	}
	if dist == unsafe { ring[3] } {
		return 3, 0
	}
	x := u32(dist + 3)
	nb := 30 - bits.leading_zeros_32(x) // floor(log2 x) - 1
	pre := (x >> nb) & 1
	return 16 + 2 * (nb - 1) + int(pre), x - ((2 + pre) << nb)
}

@[inline]
fn br_ins_code(v int) int {
	if v < 6 {
		return v
	}
	if v < 130 {
		nb := 30 - bits.leading_zeros_32(u32(v - 2))
		return nb * 2 + ((v - 2) >> nb) + 2
	}
	if v < 2114 {
		return 31 - bits.leading_zeros_32(u32(v - 66)) + 10
	}
	return if v < 6210 {
		21
	} else if v < 22594 {
		22
	} else {
		23
	}
}

@[inline]
fn br_cpy_code(v int) int {
	if v < 10 {
		return v - 2
	}
	if v < 134 {
		nb := 30 - bits.leading_zeros_32(u32(v - 6))
		return nb * 2 + ((v - 6) >> nb) + 4
	}
	if v < 2118 {
		return 31 - bits.leading_zeros_32(u32(v - 70)) + 12
	}
	return 23
}

// br_iac is the insert-and-copy symbol; implicit means distance code 0 rides in it.
@[inline]
fn br_iac(ic int, cc int, implicit bool) int {
	low := ((ic & 7) << 3) | (cc & 7)
	if implicit {
		return (if cc < 8 { 0 } else { 64 }) | low
	}
	return int(br_cells[(ic >> 3) * 3 + (cc >> 3)]) | low
}

// br_chunk writes src[at..at + n] as one meta-block, falling back to a stored one when
// that comes out shorter. Returns whether it was stored (a stored meta-block cannot be
// the last, so the stream then needs an empty last one).
@[direct_array_access]
fn (mut d Deflater) br_chunk(src &u8, at int, n int, last bool) bool {
	start := d.w
	if !d.br_parse(src, at, n) || !d.br_write(src, at, n, last) {
		return false
	}
	used := u64(unsafe { d.w.op - start.op }) * 8 + u64(d.w.cnt) - u64(start.cnt)
	if used <= u64(n + 4) * 8 {
		return false
	}
	// stored: ISLAST 0, MNIBBLES 4, MLEN - 1, ISUNCOMPRESSED, padding, the bytes
	d.w = start
	_ = d.w.put(0, 3)
	_ = d.w.put(u32(n - 1), 16)
	_ = d.w.put(1, 1)
	_ = d.w.flush()
	unsafe {
		_ = vmemcpy(d.w.op, src + at, n)
		d.w.op = d.w.op + n
	}
	return true
}

// br_parse matches the chunk into commands in d.seq, two words each: insert length |
// copy length << 16, then symbol << 22 | distance code << 16 | distance extra; and
// counts the symbols. The last command may copy nothing (copy length 0).
@[direct_array_access]
fn (mut d Deflater) br_parse(src0 &u8, at int, n int) bool {
	src := unsafe { src0 + at }
	head := d.head
	prev := d.prev
	seq := d.seq
	mut lf := &d.br.lit_freq[0]
	mut ifr := &d.br.iac_freq[0]
	mut dfr := &d.br.dist_freq[0]
	mut ring := &d.br.ring[0]
	mut hb := 10
	for hb < max_hash_bits && (1 << hb) < n {
		hb++
	}
	unsafe {
		vmemset(head, 0, (1 << hb) * 2)
		vmemset(lf, 0, 1024 * 4)
		vmemset(ifr, 0, 704 * 4)
		vmemset(dfr, 0, 64 * 4)
	}
	shift := 32 - hb
	mut ns := 0
	mut ins := 0 // next position to enter into the hash chains
	mut lit_start := 0
	mut i := 0
	for i < n {
		for ins < i && ins + min_match <= n {
			insert(head, prev, src, ins, shift)
			ins++
		}
		mut len, mut dist, mut score := br_find(head, prev, src, n, i, shift, ring, br_depth)
		ins = i + 1
		if len == 0 {
			i++
			continue
		}
		for br_lazy && len < br_nice && i + 1 < n {
			len2, dist2, score2 := br_find(head, prev, src, n, i + 1, shift, ring, if len >= good_match {
				(br_depth + 3) / 4
			} else {
				br_depth
			})
			ins = i + 2
			if score2 <= score + br_lazy_gain {
				break
			}
			i++
			len = len2
			dist = dist2
			score = score2
		}
		ilen := i - lit_start
		dcode, dx := br_dist_code(dist, ring)
		ic := br_ins_code(ilen)
		cc := br_cpy_code(len)
		implicit := dcode == 0 && ic < 8 && cc < 16
		sym := br_iac(ic, cc, implicit)
		unsafe {
			ifr[sym]++
			if !implicit {
				dfr[dcode]++
			}
			seq[ns] = u32(ilen) | u32(len) << 16
			seq[ns + 1] = u32(sym) << 22 | u32(dcode) << 16 | dx
		}
		ns += 2
		_ = br_count_literals(src0, at + lit_start, ilen, lf)
		if dcode != 0 {
			unsafe {
				ring[3] = ring[2]
				ring[2] = ring[1]
				ring[1] = ring[0]
				ring[0] = dist
			}
		}
		i += len
		lit_start = i
		if len > max_insert {
			ins = i
		}
	}
	if lit_start < n || ns == 0 {
		ilen := n - lit_start
		ic := br_ins_code(ilen)
		sym := br_iac(ic, 0, ic < 8)
		unsafe {
			ifr[sym]++
			seq[ns] = u32(ilen)
			seq[ns + 1] = u32(sym) << 22
		}
		ns += 2
		_ = br_count_literals(src0, at + lit_start, ilen, lf)
	}
	d.br.ncmd = ns
	return true
}

// br_count_literals counts n literals at src0[pos..] in the tree of the byte before each.
@[direct_array_access; inline]
fn br_count_literals(src0 &u8, pos int, n int, lf &u32) bool {
	mut p1 := if pos > 0 { unsafe { src0[pos - 1] } } else { u8(0) }
	for k in 0 .. n {
		c := unsafe { src0[pos + k] }
		unsafe {
			lf[int(br_tree_of[p1]) << 8 | c]++
		}
		p1 = c
	}
	return true
}

// br_write builds the codes and writes the meta-block: header, prefix codes, commands.
@[direct_array_access]
fn (mut d Deflater) br_write(src0 &u8, at int, n int, last bool) bool {
	ncmd := d.br.ncmd
	mut w := d.w
	if last {
		_ = w.put(1, 2) // ISLAST, not empty
	} else {
		_ = w.put(0, 1)
	}
	_ = w.put(0, 2) // MNIBBLES 4
	_ = w.put(u32(n - 1), 16)
	if !last {
		_ = w.put(0, 1) // ISUNCOMPRESSED
	}
	// one block type of each category, NPOSTFIX 0, NDIRECT 0, UTF8 context mode
	_ = w.put(0, 3)
	_ = w.put(0, 6)
	_ = w.put(2, 2)
	// NTREESL (1: a 0 bit; 2: 1, n = 0; 3-4: 1, n = 1, extra) and its context map
	if br_trees == 1 {
		_ = w.put(0, 1)
	} else if br_trees == 2 {
		_ = w.put(1, 1)
		_ = w.put(0, 3)
	} else {
		_ = w.put(1, 1)
		_ = w.put(1, 3)
		_ = w.put(u32(br_trees - 3), 1)
	}
	for e in br_cmap {
		_ = w.put(e >> 8, int(e & 0xff))
	}
	_ = w.put(0, 1) // NTREESD 1
	d.w = w
	for t in 0 .. br_trees {
		_ = d.br_prefix(&d.br.lit_freq[t << 8], 256, 8, &d.br.lit_len[t << 8], &d.br.lit_code[t << 8])
	}
	_ = d.br_prefix(&d.br.iac_freq[0], 704, 10, &d.br.iac_len[0], &d.br.iac_code[0])
	_ = d.br_prefix(&d.br.dist_freq[0], 64, 6, &d.br.dist_len[0], &d.br.dist_code[0])
	w = d.w
	seq := d.seq
	ll := &d.br.lit_len[0]
	lc := &d.br.lit_code[0]
	il := &d.br.iac_len[0]
	icd := &d.br.iac_code[0]
	dl := &d.br.dist_len[0]
	dc := &d.br.dist_code[0]
	src := unsafe { src0 + at }
	mut pos := 0
	mut p1 := if at > 0 { unsafe { src0[at - 1] } } else { u8(0) }
	for k := 0; k < ncmd; k += 2 {
		e0 := unsafe { seq[k] }
		e1 := unsafe { seq[k + 1] }
		ilen := int(e0 & 0xffff)
		clen := int(e0 >> 16)
		sym := int(e1 >> 22)
		ic := br_ins_code(ilen)
		cc := if clen == 0 { 0 } else { br_cpy_code(clen) }
		_ = w.put(unsafe { icd[sym] }, unsafe { il[sym] })
		_ = w.put(u32(ilen) - br_ins_base[ic], br_ins_xbits[ic])
		if clen > 0 {
			_ = w.put(u32(clen) - br_cpy_base[cc], br_cpy_xbits[cc])
		} else {
			_ = w.put(0, br_cpy_xbits[cc])
		}
		for j in 0 .. ilen {
			c := unsafe { src[pos + j] }
			li := int(br_tree_of[p1]) << 8 | c
			_ = w.put(unsafe { lc[li] }, unsafe { ll[li] })
			p1 = c
		}
		pos += ilen
		if clen == 0 {
			break
		}
		if sym >= 128 {
			dcode := int((e1 >> 16) & 0x3f)
			_ = w.put(unsafe { dc[dcode] }, unsafe { dl[dcode] })
			if dcode >= 16 {
				_ = w.put(e1 & 0xffff, 1 + ((dcode - 16) >> 1))
			}
		}
		pos += clen
		p1 = unsafe { src[pos - 1] }
	}
	d.w = w
	return true
}

// br_rle run-length codes lens[..n] into code length symbols (RFC 7932 3.5), the way
// the reference encoder does: 16 repeats the previous non-zero length, 17 repeats
// zero, and consecutive repeat codes multiply. Trailing zeros are left out: the
// decoder stops once the code is complete.
@[direct_array_access]
fn (mut d Deflater) br_rle(lens &u8, n0 int) {
	mut n := n0
	for n > 0 && unsafe { lens[n - 1] } == 0 {
		n--
	}
	mut rle := &d.br.rle[0]
	mut k := 0
	mut prev := u8(8)
	mut i := 0
	for i < n {
		v := unsafe { lens[i] }
		mut r := 1
		for i + r < n && unsafe { lens[i + r] } == v {
			r++
		}
		i += r
		mut reps := r
		if v != 0 {
			if prev != v {
				unsafe {
					rle[k] = v
				}
				k++
				reps--
			}
			prev = v
		}
		if reps == (if v == 0 { 11 } else { 7 }) {
			unsafe {
				rle[k] = v
			}
			k++
			reps--
		}
		if reps < 3 {
			for _ in 0 .. reps {
				unsafe {
					rle[k] = v
				}
				k++
			}
			continue
		}
		reps -= 3
		start := k
		code := if v == 0 { u16(17) } else { u16(16) }
		xbits := if v == 0 { 3 } else { 2 }
		for {
			unsafe {
				rle[k] = code | u16(reps & ((1 << xbits) - 1)) << 5
			}
			k++
			reps >>= xbits
			if reps == 0 {
				break
			}
			reps--
		}
		// emitted least significant first; the decoder reads them most significant first
		mut a := start
		mut b := k - 1
		for a < b {
			unsafe {
				t := rle[a]
				rle[a] = rle[b]
				rle[b] = t
			}
			a++
			b--
		}
	}
	d.br.nrle_cl = k
}

// br_prefix builds the code for freq[..n] into lens and codes and writes it.
fn (mut d Deflater) br_prefix(freq &u32, n int, alpha_bits int, lens &u8, codes &u16) bool {
	mut m := 0
	mut used := [4]int{}
	mut top := 0 // past the last used symbol: nothing above it is read or written
	for s in 0 .. n {
		if unsafe { freq[s] } != 0 {
			if m < 4 {
				used[m] = s
			}
			m++
			top = s + 1
		}
	}
	unsafe {
		vmemset(lens, 0, top)
		// a zero-length code must be 0 too: put ORs the value in whatever the count
		vmemset(codes, 0, top * 2)
	}
	if m <= 1 {
		// simple code of one symbol: it takes no bits at all
		_ = d.w.put(1, 2)
		_ = d.w.put(0, 2)
		_ = d.w.put(u32(used[0]), alpha_bits)
		return true
	}
	huff_lengths(mut d.keys, mut d.hwork, mut d.htmp, freq, top, 15, lens)
	_ = canonical(lens, top, codes)
	if m <= 4 {
		// simple code: symbols by length (the decoder sorts equal lengths itself)
		_ = d.w.put(1, 2)
		_ = d.w.put(u32(m - 1), 2)
		mut longest := 0
		for l in 1 .. 4 {
			for k in 0 .. m {
				if unsafe { lens[used[k]] } == l {
					_ = d.w.put(u32(used[k]), alpha_bits)
					longest = l
				}
			}
		}
		if m == 4 {
			_ = d.w.put(if longest == 3 { u32(1) } else { u32(0) }, 1)
		}
		return true
	}
	d.br_rle(lens, top)
	for k in 0 .. 18 {
		d.br.cl_freq[k] = 0
	}
	for k in 0 .. d.br.nrle_cl {
		d.br.cl_freq[d.br.rle[k] & 31]++
	}
	huff_lengths(mut d.keys, mut d.hwork, mut d.htmp, &d.br.cl_freq[0], 18, 5, &d.br.cl_len[0])
	_ = canonical(&d.br.cl_len[0], 18, &d.br.cl_code[0])
	mut hskip := 0
	if d.br.cl_len[br_cl_order[0]] == 0 && d.br.cl_len[br_cl_order[1]] == 0 {
		hskip = 2
		if d.br.cl_len[br_cl_order[2]] == 0 {
			hskip = 3
		}
	}
	mut last := 17
	for last > 0 && d.br.cl_len[br_cl_order[last]] == 0 {
		last--
	}
	_ = d.w.put(u32(hskip), 2)
	for k in hskip .. last + 1 {
		l := d.br.cl_len[br_cl_order[k]]
		_ = d.w.put(br_cl_sym[l], br_cl_bits[l])
	}
	for k in 0 .. d.br.nrle_cl {
		r := d.br.rle[k]
		sym := r & 31
		_ = d.w.put(d.br.cl_code[sym], d.br.cl_len[sym])
		if sym == 16 {
			_ = d.w.put(u32(r >> 5), 2)
		} else if sym == 17 {
			_ = d.w.put(u32(r >> 5), 3)
		}
	}
	return true
}
