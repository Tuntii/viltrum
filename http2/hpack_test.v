module http2

import encoding.hex
import os
import rand

struct RfcVector {
	id     string
	hex    string
	fields []string
	size   int
}

// list renders a decoded block as 'name: value' strings.
fn list(out []u8, fs Fields) []string {
	mut r := []string{}
	for k in 0 .. fs.n {
		f := fs.f[k]
		name := out[f.name_off..f.name_off + f.name_len].bytestr()
		value := out[f.value_off..f.value_off + f.value_len].bytestr()
		r << '${name}: ${value}'
	}
	return r
}

fn vectors(prefix string) []RfcVector {
	return rfc_vectors.filter(it.id.starts_with(prefix))
}

// huffman is the Huffman coding of s, for building test blocks.
fn huffman(s []u8) []u8 {
	mut out := []u8{}
	mut acc := u64(0)
	mut bits := 0
	for b in s {
		acc = (acc << u64(huff_len[b])) | u64(huff_code[b])
		bits += int(huff_len[b])
		for bits >= 8 {
			bits -= 8
			out << u8(acc >> u64(bits))
		}
	}
	if bits > 0 {
		// pad with the high bits of EOS (all ones)
		out << u8((acc << u64(8 - bits)) | ((u64(1) << u64(8 - bits)) - 1))
	}
	return out
}

fn fuzz_iters(default_n int) int {
	n := os.getenv('VILTRUM_FUZZ_ITERS').int()
	return if n > 0 { n } else { default_n }
}

fn test_static_table() {
	assert static_names.len == static_len + 1
	assert static_values.len == static_len + 1
	assert static_names[1] == ':authority'
	assert static_names[61] == 'www-authenticate'
	assert static_values[16] == 'gzip, deflate'
}

// RFC 7541 C.1
fn test_integers() {
	mut out := []u8{}
	write_int(mut out, 0, 5, 10)
	assert out == [u8(0x0a)]
	out.clear()
	write_int(mut out, 0, 5, 1337)
	assert out == [u8(0x1f), 0x9a, 0x0a]
	out.clear()
	write_int(mut out, 0, 8, 42)
	assert out == [u8(0x2a)]
	v, p := read_int([u8(0x1f), 0x9a, 0x0a], 0, 5)
	assert v == 1337 && p == 3
	for n in [0, 1, 30, 31, 127, 128, 255, 4096, 65535, 1 << 20, max_int] {
		for prefix in [4, 5, 6, 7, 8] {
			out.clear()
			write_int(mut out, 0, prefix, n)
			got, q := read_int(out, 0, prefix)
			assert got == n && q == out.len, '${n} with a ${prefix}-bit prefix'
		}
	}
	// cut short, and too large
	_, p2 := read_int([u8(0x1f), 0x9a], 0, 5)
	assert p2 == -1
	_, p3 := read_int([u8(0x1f), 0xff, 0xff, 0xff, 0xff, 0x0f], 0, 5)
	assert p3 == -1
}

// check_decode runs a group of Appendix C examples through one decoder.
fn check_decode(prefix string, table_size int) {
	mut d := new_decoder(table_size)
	for v in vectors(prefix) {
		mut out := []u8{}
		mut fs := Fields{}
		assert d.decode(hex.decode(v.hex) or { panic(err) }, mut out, mut fs, 1 << 20) == hpack_ok, v.id
		assert list(out, fs) == v.fields, v.id
		assert d.t.size == v.size, v.id
	}
}

fn test_rfc_decode() {
	for id in ['C.2.1', 'C.2.2', 'C.2.3', 'C.2.4'] {
		check_decode(id, default_table_size)
	}
	check_decode('C.3.', default_table_size) // requests
	check_decode('C.4.', default_table_size) // the same, Huffman-coded
	check_decode('C.5.', 256) // responses, with evictions
	check_decode('C.6.', 256) // the same, Huffman-coded
}

// check_encode encodes a group of the examples that use no Huffman coding and
// compares the bytes. idx is how the RFC encodes the fields it does not index.
fn check_encode(prefix string, table_size int, idx Index) {
	mut e := new_encoder(table_size)
	for v in vectors(prefix) {
		mut out := []u8{}
		e.begin(mut out)
		for f in v.fields {
			k := f.index(': ') or { panic(f) }
			e.field(mut out, f[..k], f[k + 2..], idx)
		}
		assert hex.encode(out) == v.hex, v.id
		assert e.t.size == v.size, v.id
	}
}

fn test_rfc_encode() {
	check_encode('C.2.1', default_table_size, .incremental)
	check_encode('C.2.2', default_table_size, .without)
	check_encode('C.2.3', default_table_size, .never)
	check_encode('C.2.4', default_table_size, .incremental)
	check_encode('C.3.', default_table_size, .incremental)
	check_encode('C.5.', 256, .incremental)
}

fn test_encoder_lowercases_names() {
	mut e := new_encoder(default_table_size)
	mut out := []u8{}
	e.field(mut out, 'Content-Type', 'text/plain', .incremental)
	e.field(mut out, 'X-Custom', 'v', .incremental)
	e.field(mut out, 'CONTENT-TYPE', 'text/plain', .incremental) // the entry just added
	mut d := new_decoder(default_table_size)
	mut dec := []u8{}
	mut fs := Fields{}
	assert d.decode(out, mut dec, mut fs, 1 << 20) == hpack_ok
	assert list(dec, fs) == ['content-type: text/plain', 'x-custom: v', 'content-type: text/plain']
	assert out.last() == 0x80 | u8(static_len + 2)
}

fn test_huffman_padding() {
	// 'a' is 00011: padded with ones it is valid, with zeros it is not
	mut out := []u8{}
	assert huff_decode([u8(0x1f)], 0, 1, mut out) && out == 'a'.bytes()
	out.clear()
	assert !huff_decode([u8(0x18)], 0, 1, mut out)
	// eight bits of padding (a whole byte of ones after a symbol) is too many
	assert !huff_decode([u8(0x1f), 0xff], 0, 2, mut out)
	// EOS itself (30 ones), with two more of padding
	assert !huff_decode([u8(0xff), 0xff, 0xff, 0xff], 0, 4, mut out)
	// every byte value round trips
	mut all := []u8{len: 256, init: u8(index)}
	out.clear()
	enc := huffman(all)
	assert huff_decode(enc, 0, enc.len, mut out) && out == all
}

fn test_decode_errors() {
	cases := {
		'index 0':                 [u8(0x80)]
		'index past the tables':   [u8(0xbe)]
		'size update past limit':  [u8(0x3f), 0xe2, 0x1f] // 4097
		'size update after field': [u8(0x82), 0x20]
		'literal name cut short':  [u8(0x40), 0x0a, `c`]
		'literal value cut short': [u8(0x40), 0x01, `a`, 0x05, `b`]
		'name index past tables':  [u8(0x7e), 0x01, `a`]
		'integer too large':       [u8(0xff), 0xff, 0xff, 0xff, 0xff, 0x0f]
		'bad huffman value':       [u8(0x40), 0x01, `a`, 0x81, 0x18]
	}
	for name, block in cases {
		mut d := new_decoder(default_table_size)
		mut out := []u8{}
		mut fs := Fields{}
		assert d.decode(block, mut out, mut fs, 1 << 20) == hpack_bad, name
	}
	// a size update at the start is fine, and so are two in a row
	mut d := new_decoder(default_table_size)
	mut out := []u8{}
	mut fs := Fields{}
	assert d.decode([u8(0x20), 0x3f, 0xe1, 0x1f, 0x82], mut out, mut fs, 1 << 20) == hpack_ok
	assert d.t.max == default_table_size && list(out, fs) == [':method: GET']
}

// A list over the limit is refused, but what it added to the table is kept, so the
// next block that refers to it still decodes.
fn test_too_large_keeps_the_table() {
	mut e := new_encoder(default_table_size)
	mut d := new_decoder(default_table_size)
	big := 'x'.repeat(300)
	mut b1 := []u8{}
	e.field(mut b1, ':method', 'GET', .incremental)
	e.field(mut b1, 'big', big, .incremental)
	e.field(mut b1, 'after', 'kept', .incremental)
	mut out := []u8{}
	mut fs := Fields{}
	assert d.decode(b1, mut out, mut fs, 200) == hpack_too_large
	assert list(out, fs) == [':method: GET']
	assert d.t.size == e.t.size && d.t.count == 2
	mut b2 := []u8{}
	e.field(mut b2, 'big', big, .incremental)
	e.field(mut b2, 'after', 'kept', .incremental)
	assert b2 == [u8(0x80 | (static_len + 2)), u8(0x80 | (static_len + 1))]
	out.clear()
	assert d.decode(b2, mut out, mut fs, 1 << 20) == hpack_ok
	assert list(out, fs) == ['big: ${big}', 'after: kept']
	// more fields than a block reports is the same refusal
	mut b3 := []u8{}
	for _ in 0 .. max_block_fields + 1 {
		e.field(mut b3, ':method', 'GET', .incremental)
	}
	out.clear()
	assert d.decode(b3, mut out, mut fs, 1 << 20) == hpack_too_large && fs.n == max_block_fields
}

fn test_encoder_size_updates() {
	mut e := new_encoder(default_table_size)
	mut d := new_decoder(default_table_size)
	mut out := []u8{}
	e.field(mut out, 'a', 'b', .incremental)
	mut dec := []u8{}
	mut fs := Fields{}
	assert d.decode(out, mut dec, mut fs, 1 << 20) == hpack_ok
	// the peer shrinks the table to 0 and back: the next block says both, smallest first
	e.set_limit(0)
	e.set_limit(8192)
	out.clear()
	e.begin(mut out)
	e.field(mut out, 'a', 'b', .incremental)
	assert out[..4] == [u8(0x20), 0x3f, 0xe1, 0x1f]
	dec.clear()
	assert d.decode(out, mut dec, mut fs, 1 << 20) == hpack_ok
	assert list(dec, fs) == ['a: b'] && d.t.size == e.t.size && d.t.count == 1
	// nothing owed now
	out.clear()
	e.begin(mut out)
	assert out.len == 0
}

// random lists through an Encoder and back, the two tables in step after each block
fn test_round_trip_fuzz() {
	mut e := new_encoder(default_table_size)
	mut d := new_decoder(default_table_size)
	names := [':status', 'content-type', 'x-a', 'x-b', 'set-cookie', 'date', 'server', 'etag']
	for it in 0 .. fuzz_iters(2000) {
		if it % 97 == 0 {
			e.set_limit(rand.intn(default_table_size + 1) or { 0 })
		}
		mut out := []u8{}
		e.begin(mut out)
		mut want := []string{}
		for _ in 0 .. rand.intn(12) or { 0 } {
			name := if rand.intn(4) or { 0 } == 0 {
				rand.string(rand.intn(20) or { 0 } + 1).to_lower()
			} else {
				names[rand.intn(names.len) or { 0 }]
			}
			value := rand.string(rand.intn(if rand.intn(10) or { 0 } == 0 { 5000 } else { 30 }) or {
				0
			})
			idx := [Index.incremental, .without, .never][rand.intn(3) or { 0 }]
			e.field(mut out, name, value, idx)
			want << '${name}: ${value}'
		}
		mut dec := []u8{}
		mut fs := Fields{}
		assert d.decode(out, mut dec, mut fs, 1 << 24) == hpack_ok
		assert list(dec, fs) == want
		assert d.t.size == e.t.size && d.t.count == e.t.count && d.t.max == e.t.max
	}
}

// mutated blocks, raw and Huffman-coded, never upset the decoder
fn test_mutation_fuzz() {
	mut seeds := rfc_vectors.map(hex.decode(it.hex) or { panic(err) })
	mut lit := [u8(0x40), 0x80 | 3]
	lit << huffman('abc'.bytes())
	lit << 0x80 | 3
	lit << huffman('xyz'.bytes())
	seeds << lit
	for it in 0 .. fuzz_iters(20000) {
		mut b := seeds[it % seeds.len].clone()
		for _ in 0 .. 1 + rand.intn(4) or { 0 } {
			match rand.intn(3) {
				0 {
					if b.len > 0 {
						b[rand.intn(b.len) or { 0 }] = u8(rand.intn(256) or { 0 })
					}
				}
				1 {
					if b.len > 0 {
						b = b[..rand.intn(b.len) or { 0 }].clone()
					}
				}
				else {
					b.insert(rand.intn(b.len + 1) or { 0 }, u8(rand.intn(256) or { 0 }))
				}
			} or { 0 }
		}
		mut d := new_decoder(256 + rand.intn(default_table_size) or { 0 })
		mut out := []u8{}
		mut fs := Fields{}
		r := d.decode(b, mut out, mut fs, 1 << 16)
		assert r == hpack_ok || r == hpack_bad || r == hpack_too_large
		assert d.t.size <= d.t.max
	}
}

// RFC 7541 Appendix C, copied from the RFC: each block, the list it decodes to, and
// the dynamic table size after it (0 where it is empty).
const rfc_vectors = [
	RfcVector{
		id:     'C.2.1'
		hex:    '400a637573746f6d2d6b65790d637573746f6d2d686561646572'
		fields: ['custom-key: custom-header']
		size:   55
	},
	RfcVector{
		id:     'C.2.2'
		hex:    '040c2f73616d706c652f70617468'
		fields: [':path: /sample/path']
		size:   0
	},
	RfcVector{
		id:     'C.2.3'
		hex:    '100870617373776f726406736563726574'
		fields: ['password: secret']
		size:   0
	},
	RfcVector{
		id:     'C.2.4'
		hex:    '82'
		fields: [':method: GET']
		size:   0
	},
	RfcVector{
		id:     'C.3.1'
		hex:    '828684410f7777772e6578616d706c652e636f6d'
		fields: [':method: GET', ':scheme: http', ':path: /', ':authority: www.example.com']
		size:   57
	},
	RfcVector{
		id:     'C.3.2'
		hex:    '828684be58086e6f2d6361636865'
		fields: [':method: GET', ':scheme: http', ':path: /', ':authority: www.example.com',
			'cache-control: no-cache']
		size:   110
	},
	RfcVector{
		id:     'C.3.3'
		hex:    '828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565'
		fields: [':method: GET', ':scheme: https', ':path: /index.html',
			':authority: www.example.com', 'custom-key: custom-value']
		size:   164
	},
	RfcVector{
		id:     'C.4.1'
		hex:    '828684418cf1e3c2e5f23a6ba0ab90f4ff'
		fields: [':method: GET', ':scheme: http', ':path: /', ':authority: www.example.com']
		size:   57
	},
	RfcVector{
		id:     'C.4.2'
		hex:    '828684be5886a8eb10649cbf'
		fields: [':method: GET', ':scheme: http', ':path: /', ':authority: www.example.com',
			'cache-control: no-cache']
		size:   110
	},
	RfcVector{
		id:     'C.4.3'
		hex:    '828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf'
		fields: [':method: GET', ':scheme: https', ':path: /index.html',
			':authority: www.example.com', 'custom-key: custom-value']
		size:   164
	},
	RfcVector{
		id:     'C.5.1'
		hex:    '4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d546e1768747470733a2f2f7777772e6578616d706c652e636f6d'
		fields: [':status: 302', 'cache-control: private', 'date: Mon, 21 Oct 2013 20:13:21 GMT',
			'location: https://www.example.com']
		size:   222
	},
	RfcVector{
		id:     'C.5.2'
		hex:    '4803333037c1c0bf'
		fields: [':status: 307', 'cache-control: private', 'date: Mon, 21 Oct 2013 20:13:21 GMT',
			'location: https://www.example.com']
		size:   222
	},
	RfcVector{
		id:     'C.5.3'
		hex:    '88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d4153444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31'
		fields: [':status: 200', 'cache-control: private', 'date: Mon, 21 Oct 2013 20:13:22 GMT',
			'location: https://www.example.com', 'content-encoding: gzip',
			'set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1']
		size:   215
	},
	RfcVector{
		id:     'C.6.1'
		hex:    '488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3'
		fields: [':status: 302', 'cache-control: private', 'date: Mon, 21 Oct 2013 20:13:21 GMT',
			'location: https://www.example.com']
		size:   222
	},
	RfcVector{
		id:     'C.6.2'
		hex:    '4883640effc1c0bf'
		fields: [':status: 307', 'cache-control: private', 'date: Mon, 21 Oct 2013 20:13:21 GMT',
			'location: https://www.example.com']
		size:   222
	},
	RfcVector{
		id:     'C.6.3'
		hex:    '88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007'
		fields: [':status: 200', 'cache-control: private', 'date: Mon, 21 Oct 2013 20:13:22 GMT',
			'location: https://www.example.com', 'content-encoding: gzip',
			'set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1']
		size:   215
	},
]
