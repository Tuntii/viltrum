module http1

import compress.gzip as vgzip

// rand_bytes is a fixed pseudo-random sequence over the first k byte values.
fn rand_bytes(n int, k int, seed u32) []u8 {
	mut out := []u8{len: n}
	mut x := seed
	for i in 0 .. n {
		x = x * 1664525 + 1013904223
		out[i] = u8((x >> 16) % u32(k))
	}
	return out
}

fn round_trip(mut d Deflater, src []u8, label string) {
	packed := d.gzip(src) or { panic(err) }
	assert packed.len <= 10 + src.len + 5 * (src.len / max_chunk + 1) + 8, label
	back := vgzip.decompress(packed) or { panic('${label}: ${err}') }
	assert back == src, label
}

fn test_round_trips_edge_shapes() {
	mut d := new_deflater()
	round_trip(mut d, []u8{}, 'empty')
	round_trip(mut d, [u8(7)], 'one byte')
	for n in [3, 4, 5, 257, 258, 259, 260, 1000, 70000] {
		round_trip(mut d, []u8{len: n, init: `a`}, 'run ${n}')
	}
	round_trip(mut d, 'abcabcabcabcabcabcabcabcabcabcabcabcabcabcabc'.bytes(), 'period 3')
	round_trip(mut d, '{"a":1}'.repeat(5000).bytes(), 'json repeat')
}

fn test_round_trips_across_chunks() {
	mut d := new_deflater()
	for n in [max_chunk - 1, max_chunk, max_chunk + 1, 2 * max_chunk + 7, 200000] {
		round_trip(mut d, rand_bytes(n, 256, u32(n)), 'random ${n}')
		round_trip(mut d, rand_bytes(n, 4, u32(n)), 'alphabet 4, ${n}')
	}
}

fn test_round_trips_mixed() {
	mut d := new_deflater()
	for seed in 0 .. 200 {
		n := int((u32(seed) * 2654435761) % 20000)
		k := [2, 3, 16, 64, 256][seed % 5]
		round_trip(mut d, rand_bytes(n, k, u32(seed)), 'seed ${seed}')
	}
}

fn test_round_trips_json_pages() {
	mut d := new_deflater()
	mut page := '{"items":['
	for i in 0 .. 50 {
		if i > 0 {
			page += ','
		}
		page += '{"id":${i},"name":"Item ${i * 7 % 13}","category":"tools","price":${i * 31 % 500},"quantity":${i % 9},"active":${i % 2 == 0},"tags":["sale","new"],"rating":{"score":${i % 50},"count":${i * 3}},"total":${i * 977}}'
	}
	page += '],"count":50}'
	src := page.bytes()
	round_trip(mut d, src, 'json page')
	packed := d.gzip(src)!
	assert packed.len * 4 < src.len // compresses like JSON should
}

fn test_crc32() {
	assert crc32(c'123456789', 9) == 0xcbf43926
	src := rand_bytes(1001, 256, 9)
	mut bitwise := u32(0xffffffff)
	for b in src {
		bitwise ^= b
		for _ in 0 .. 8 {
			bitwise = if bitwise & 1 != 0 { (bitwise >> 1) ^ 0xedb88320 } else { bitwise >> 1 }
		}
	}
	assert crc32(src.data, src.len) == ~bitwise
}

fn test_symbol_tables_cover_every_length_and_distance() {
	for dist in 1 .. window_size + 1 {
		s := dist_sym(dist)
		base := int(dist_base[s])
		assert dist >= base && dist < base + (1 << int(dist_xbits[s])), 'distance ${dist}'
	}
	for l in 3 .. max_match + 1 {
		s := len_sym[l]
		base := int(len_base[s])
		assert l >= base && l < base + (1 << int(len_xbits[s])), 'length ${l}'
	}
}
