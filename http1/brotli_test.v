module http1

import os
import rand

// A test-only Brotli decoder for what the encoder emits (RFC 7932 without the static
// dictionary, block switching or postfix/direct distances), written from the RFC with
// its own context tables, so a shared mistake has to be made twice. The tests below
// also run the reference `brotli` tool when it is installed.

struct BrReader {
	data []u8
mut:
	pos int // bit position
}

fn (mut r BrReader) bits(n int) !u32 {
	mut v := u32(0)
	for k in 0 .. n {
		byte_at := r.pos >> 3
		if byte_at >= r.data.len {
			return error('brotli: out of input')
		}
		v |= u32((r.data[byte_at] >> (r.pos & 7)) & 1) << k
		r.pos++
	}
	return v
}

struct BrDecCode {
mut:
	count  [16]int
	syms   []int
	single int = -1 // a one-symbol code: no bits
}

fn br_dec_code(lens []u8) BrDecCode {
	mut c := BrDecCode{}
	for l in 1 .. 16 {
		for s, sl in lens {
			if sl == l {
				c.count[l]++
				c.syms << s
			}
		}
	}
	return c
}

fn (c &BrDecCode) decode(mut r BrReader) !int {
	if c.single >= 0 {
		return c.single
	}
	mut code := 0
	mut first := 0
	mut index := 0
	for l in 1 .. 16 {
		code |= int(r.bits(1)!)
		count := c.count[l]
		if code - count < first {
			return c.syms[index + (code - first)]
		}
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	return error('brotli: bad code')
}

fn br_alpha_bits(size int) int {
	mut b := 0
	for (1 << b) < size {
		b++
	}
	return b
}

const br_test_cl_order = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]

fn br_read_code(mut r BrReader, size int) !BrDecCode {
	hskip := int(r.bits(2)!)
	mut lens := []u8{len: size}
	if hskip == 1 {
		nsym := int(r.bits(2)!) + 1
		ab := br_alpha_bits(size)
		mut syms := []int{}
		for _ in 0 .. nsym {
			s := int(r.bits(ab)!)
			if s >= size || s in syms {
				return error('brotli: bad simple code')
			}
			syms << s
		}
		if nsym == 1 {
			mut c := BrDecCode{}
			c.single = syms[0]
			return c
		}
		shape := match nsym {
			2 { [u8(1), 1] }
			3 { [u8(1), 2, 2] }
			else { if r.bits(1)! == 1 { [u8(1), 2, 3, 3] } else { [u8(2), 2, 2, 2] } }
		}
		for k, s in syms {
			lens[s] = shape[k]
		}
		return br_dec_code(lens)
	}
	mut cl := []u8{len: 18}
	mut space := 32
	mut ncodes := 0
	for k in hskip .. 18 {
		// the fixed code for code length code lengths, read bit by bit
		mut l := 0
		b0 := r.bits(2)!
		match b0 {
			0 { l = 0 }
			2 { l = 3 }
			1 { l = 4 }
			else {
				if r.bits(1)! == 0 {
					l = 2
				} else {
					l = if r.bits(1)! == 0 { 1 } else { 5 }
				}
			}
		}
		cl[br_test_cl_order[k]] = u8(l)
		if l != 0 {
			space -= 32 >> l
			ncodes++
			if space <= 0 {
				break
			}
		}
	}
	if ncodes != 1 && space != 0 {
		return error('brotli: incomplete code length code')
	}
	mut clc := br_dec_code(cl)
	if ncodes == 1 {
		for s, l in cl {
			if l != 0 {
				clc.single = s
			}
		}
	}
	mut prev := u8(8)
	mut repeat := 0
	mut repeat_len := u8(0)
	mut sp := 32768
	mut i := 0
	for i < size && sp > 0 {
		s := clc.decode(mut r)!
		if s < 16 {
			lens[i] = u8(s)
			i++
			repeat = 0
			if s != 0 {
				prev = u8(s)
				sp -= 32768 >> s
			}
			continue
		}
		xb := if s == 16 { 2 } else { 3 }
		nl := if s == 16 { prev } else { u8(0) }
		if repeat_len != nl {
			repeat = 0
			repeat_len = nl
		}
		old := repeat
		if repeat > 0 {
			repeat -= 2
			repeat <<= xb
		}
		repeat += int(r.bits(xb)!) + 3
		delta := repeat - old
		if i + delta > size {
			return error('brotli: repeat past the alphabet')
		}
		for _ in 0 .. delta {
			lens[i] = nl
			i++
			if nl != 0 {
				sp -= 32768 >> int(nl) // int: with a u8 on the right, V types the literal u8
			}
		}
	}
	if sp != 0 {
		return error('brotli: incomplete code (alphabet ${size}, ${i} lengths, space ${sp})')
	}
	return br_dec_code(lens)
}

fn br_read_nblt(mut r BrReader) !int {
	if r.bits(1)! == 0 {
		return 1
	}
	n := int(r.bits(3)!)
	if n == 0 {
		return 2
	}
	return (1 << n) + int(r.bits(n)!) + 1
}

fn br_read_cmap(mut r BrReader, size int, ntrees int) ![]u8 {
	mut rlemax := 0
	if r.bits(1)! == 1 {
		rlemax = int(r.bits(4)!) + 1
	}
	code := br_read_code(mut r, ntrees + rlemax)!
	mut m := []u8{}
	for m.len < size {
		s := code.decode(mut r)!
		if s == 0 {
			m << 0
		} else if s <= rlemax {
			reps := (1 << s) + int(r.bits(s)!)
			for _ in 0 .. reps {
				m << 0
			}
		} else {
			m << u8(s - rlemax)
		}
	}
	if m.len != size {
		return error('brotli: context map overrun')
	}
	if r.bits(1)! == 1 {
		mut mtf := []u8{len: 256, init: u8(index)}
		for k in 0 .. m.len {
			idx := int(m[k])
			v := mtf[idx]
			m[k] = v
			for j := idx; j > 0; j-- {
				mtf[j] = mtf[j - 1]
			}
			mtf[0] = v
		}
	}
	return m
}

// RFC 7932 7.1, UTF8 mode
const br_lut0 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 8, 12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12, 44, 44, 44,
	44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12, 12, 48, 52, 52, 52, 48, 52, 52, 52, 48,
	52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12, 12,
	56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56, 60, 60,
	60, 60, 60, 24, 12, 28, 12, 0]

fn br_lut(p1 u8, p2 u8) int {
	l0 := if p1 < 128 {
		br_lut0[p1]
	} else if p1 < 192 {
		int(p1 & 1)
	} else {
		2 + int(p1 & 1)
	}
	l1 := if p2 <= 32 {
		0
	} else if p2 < 128 {
		if p2 >= `0` && p2 <= `9` {
			2
		} else if p2 >= `A` && p2 <= `Z` {
			2
		} else if p2 >= `a` && p2 <= `z` {
			3
		} else if p2 == 127 {
			0
		} else {
			1
		}
	} else if p2 < 192 {
		0
	} else {
		2
	}
	return l0 | l1
}

const br_test_ins_base = [0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322,
	578, 1090, 2114, 6210, 22594]
const br_test_ins_x = [0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24]
const br_test_cpy_base = [2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134,
	198, 326, 582, 1094, 2118]
const br_test_cpy_x = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24]
const br_test_cells = [[0, 0], [0, 1], [1, 0], [1, 1], [0, 2], [2, 0], [1, 2], [2, 1], [2, 2]]

fn br_decode(data []u8) ![]u8 {
	mut r := BrReader{
		data: data
	}
	if r.bits(1)! != 0 {
		return error('brotli: only WBITS 16 here')
	}
	mut out := []u8{}
	mut ring := [4, 11, 15, 16]
	for {
		islast := r.bits(1)! == 1
		if islast && r.bits(1)! == 1 {
			break
		}
		mnib := int(r.bits(2)!)
		if mnib == 3 {
			return error('brotli: metadata block')
		}
		mlen := int(r.bits(4 * (mnib + 4))!) + 1
		if !islast && r.bits(1)! == 1 {
			for r.pos & 7 != 0 {
				if r.bits(1)! != 0 {
					return error('brotli: padding not zero')
				}
			}
			at := r.pos >> 3
			if at + mlen > data.len {
				return error('brotli: short stored block')
			}
			out << data[at..at + mlen]
			r.pos += 8 * mlen
			continue
		}
		for _ in 0 .. 3 {
			if br_read_nblt(mut r)! != 1 {
				return error('brotli: block switching')
			}
		}
		if r.bits(6)! != 0 {
			return error('brotli: NPOSTFIX/NDIRECT')
		}
		cmode := int(r.bits(2)!)
		ntl := br_read_nblt(mut r)!		cmapl := if ntl >= 2 { br_read_cmap(mut r, 64, ntl)! } else { []u8{len: 64} }
		ntd := br_read_nblt(mut r)!
		cmapd := if ntd >= 2 { br_read_cmap(mut r, 4, ntd)! } else { []u8{len: 4} }
		mut lit := []BrDecCode{}
		for _ in 0 .. ntl {
			lit << br_read_code(mut r, 256)!
		}
		iac := br_read_code(mut r, 704)!
		mut dist := []BrDecCode{}
		for _ in 0 .. ntd {
			dist << br_read_code(mut r, 64)!
		}
		mut left := mlen
		for left > 0 {
			sym := iac.decode(mut r)!
			mut ic := 0
			mut cc := 0
			implicit := sym < 128
			if implicit {
				ic = (sym >> 3) & 7
				cc = (sym & 7) | (if sym >= 64 { 8 } else { 0 })
			} else {
				cell := br_test_cells[(sym - 128) >> 6]
				ic = cell[0] * 8 + ((sym >> 3) & 7)
				cc = cell[1] * 8 + (sym & 7)
			}
			ilen := br_test_ins_base[ic] + int(r.bits(br_test_ins_x[ic])!)
			clen := br_test_cpy_base[cc] + int(r.bits(br_test_cpy_x[cc])!)
			for _ in 0 .. ilen {
				p1 := if out.len > 0 { out[out.len - 1] } else { u8(0) }
				p2 := if out.len > 1 { out[out.len - 2] } else { u8(0) }
				ctx := match cmode {
					0 { int(p1 & 0x3f) }
					1 { int(p1 >> 2) }
					2 { br_lut(p1, p2) }
					else { return error('brotli: signed context mode') }
				}
				out << u8(lit[cmapl[ctx]].decode(mut r)!)
				left--
			}
			if left <= 0 {
				break
			}
			mut dcode := 0
			if !implicit {
				dctx := if clen > 4 { 3 } else { clen - 2 }
				dcode = dist[cmapd[dctx]].decode(mut r)!
			}
			mut d := 0
			if dcode < 16 {
				d = match dcode {
					0 { ring[0] }
					1 { ring[1] }
					2 { ring[2] }
					3 { ring[3] }
					4 { ring[0] - 1 }
					5 { ring[0] + 1 }
					6 { ring[0] - 2 }
					7 { ring[0] + 2 }
					8 { ring[0] - 3 }
					9 { ring[0] + 3 }
					10 { ring[1] - 1 }
					11 { ring[1] + 1 }
					12 { ring[1] - 2 }
					13 { ring[1] + 2 }
					14 { ring[1] - 3 }
					else { ring[1] + 3 }
				}
			} else {
				nb := 1 + ((dcode - 16) >> 1)
				off := ((2 + ((dcode - 16) & 1)) << nb) - 4
				d = off + int(r.bits(nb)!) + 1
			}
			if d <= 0 || d > out.len || d > 65520 {
				return error('brotli: distance ${d} at ${out.len}')
			}
			if dcode != 0 {
				ring = [d, ring[0], ring[1], ring[2]]
			}
			if clen > left {
				return error('brotli: copy past the meta-block')
			}
			for _ in 0 .. clen {
				out << out[out.len - d]
			}
			left -= clen
		}
		if left != 0 {
			return error('brotli: meta-block length mismatch')
		}
		if islast {
			break
		}
	}
	return out
}

fn br_samples() [][]u8 {
	mut s := [][]u8{}
	s << []u8{}
	s << 'a'.bytes()
	s << 'hello, hello, hello world'.bytes()
	mut j := '{"items":['
	for i in 0 .. 50 {
		if i > 0 {
			j += ','
		}
		j += '{"id":${i + 1},"name":"Item ${i * 7919 % 1000}","category":"${['electronics',
			'books', 'auto', 'garden'][i % 4]}","price":${i * 37 % 500},"quantity":${i * 13 % 90},"active":${i % 3 == 0},"tags":["fast","new"],"rating":{"score":${i % 50},"count":${i * 11}},"total":${i * 991}}'
	}
	j += '],"count":50}'
	s << j.bytes()
	s << []u8{len: 100000, init: u8(`x`)} // long copies: copy codes with 24 extra bits
	s << []u8{len: 3000, init: u8(index % 3)} // few symbols: simple prefix codes
	mut rnd := []u8{len: 70000}
	rand.seed([u32(7), 11])
	for k in 0 .. rnd.len {
		rnd[k] = u8(rand.u32())
	}
	s << rnd // incompressible: stored meta-blocks, two chunks
	mut text := []u8{}
	for text.len < 200000 {
		text << 'The quick brown fox jumps over the lazy dog ${text.len % 977}. '.bytes()
	}
	s << text // several chunks
	return s
}

fn test_brotli_roundtrip() {
	mut d := new_deflater()
	for src in br_samples() {
		enc := d.brotli(src) or { panic(err) }
		dec := br_decode(enc.clone()) or { panic('${src.len} bytes: ${err}') }
		assert dec == src, '${src.len} bytes'
	}
}

fn test_brotli_beats_gzip_on_json() {
	mut d := new_deflater()
	j := br_samples()[3]
	br := d.brotli(j)!.len
	gz := d.gzip(j)!.len
	assert br < gz, 'br ${br} gz ${gz}'
}

struct BrMsg {
	message string
}

const br_msg = 'brotli '.repeat(100)

fn br_json(mut c Ctx) {
	c.json(200, BrMsg{ message: br_msg })
}

fn br_run(ae string) !Ctx {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\nAccept-Encoding: ${ae}\r\n\r\n')!
	c.deflater = new_deflater()
	c.chain = [Handler(compress_middleware), br_json]
	c.chain[0](mut c)
	return c
}

fn br_body(c Ctx) []u8 {
	s := c.out.bytestr()
	return c.out[s.index('\r\n\r\n') or { panic('no head') } + 4..].clone()
}

fn test_compress_middleware_negotiates() {
	want := '{"message":"${br_msg}"}'
	for ae, coding in {
		'gzip, br':        'br'
		'br;q=0.5, gzip':  'gzip'
		'gzip;q=0.5, br':  'br'
		'*':               'br'
		'gzip':            'gzip'
		'br;q=0, gzip':    'gzip'
		'identity':        ''
	} {
		c := br_run(ae)!
		s := c.out.bytestr()
		assert s.contains('Vary: Accept-Encoding\r\n'), ae
		body := br_body(c)
		assert s.contains('Content-Length: ${body.len}\r\n'), ae
		if coding == '' {
			assert !s.contains('Content-Encoding'), ae
			assert body.bytestr() == want, ae
			continue
		}
		assert s.contains('Content-Encoding: ${coding}\r\n'), ae
		if coding == 'br' {
			assert br_decode(body)!.bytestr() == want, ae
		}
	}
}

fn test_compress_middleware_allocates_nothing() {
	raw := 'GET /j HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip, br\r\n\r\n'.bytes()
	mut f := Frame{}
	n := frame(raw, mut f, Limits{})!
	mut c := Ctx.new()
	c.out = []u8{cap: 8192}
	c.deflater = new_deflater()
	c.chain = [Handler(compress_middleware), Handler(br_json)]
	for _ in 0 .. 100 {
		br_serve(mut c, raw, f, n)
	}
	before := allocated_bytes()
	for _ in 0 .. 5000 {
		br_serve(mut c, raw, f, n)
	}
	assert allocated_bytes() - before == 0
}

fn br_serve(mut c Ctx, raw []u8, f Frame, n int) {
	unsafe {
		c.out.len = 0
	}
	parse_head(raw, f.head_end, mut c.head) or { panic(err) }
	c.begin(view(raw, 0, n))
	c.set_body(view(raw, f.head_end, f.content_length))
	c.chain[0](mut c)
}

// the reference decoder, when the brotli tool is installed
fn test_brotli_reference_decoder() {
	if os.find_abs_path_of_executable('brotli') or { '' } == '' {
		eprintln('skipped: no brotli tool')
		return
	}
	dir := os.join_path(os.temp_dir(), 'viltrum_br_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	mut d := new_deflater()
	for k, src in br_samples() {
		enc := os.join_path(dir, '${k}.br')
		dec := os.join_path(dir, '${k}.out')
		os.write_file_array(enc, d.brotli(src)!)!
		// to a file: stdout would not carry binary through on Windows
		res := os.execute('brotli -d -f -o ${os.quoted_path(dec)} ${os.quoted_path(enc)}')
		assert res.exit_code == 0, '${src.len} bytes: ${res.output}'
		assert os.read_bytes(dec)! == src, '${src.len} bytes'
	}
}
