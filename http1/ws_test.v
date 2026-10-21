module http1

import crypto.sha1 as vsha1

fn noise(n int, seed u32) []u8 {
	mut out := []u8{len: n}
	mut x := seed
	for i in 0 .. n {
		x = x * 1664525 + 1013904223
		out[i] = u8(x >> 16)
	}
	return out
}

fn test_sha1_matches_the_standard_library() {
	for n in 0 .. 120 {
		src := noise(n, u32(n + 1))
		mut d := [20]u8{}
		sha1(src.data, n, mut d)
		assert d[..] == vsha1.sum(src), 'length ${n}'
	}
}

fn test_ws_accept_rfc_example() {
	mut out := [28]u8{}
	ws_accept('dGhlIHNhbXBsZSBub25jZQ==', mut out)
	assert out[..].bytestr() == 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
}

fn test_ws_key_shape() {
	assert valid_ws_key('dGhlIHNhbXBsZSBub25jZQ==')
	assert !valid_ws_key('dGhlIHNhbXBsZSBub25jZQ=')
	assert !valid_ws_key('dGhlIHNhbXBsZSBub25jZQ=x')
	assert !valid_ws_key('dGhlIHNhbXBsZSBub25jZ!==')
}

// encode is a reference UTF-8 encoder for one scalar value.
fn encode(r u32) []u8 {
	if r < 0x80 {
		return [u8(r)]
	}
	if r < 0x800 {
		return [u8(0xc0 | r >> 6), u8(0x80 | r & 0x3f)]
	}
	if r < 0x10000 {
		return [u8(0xe0 | r >> 12), u8(0x80 | (r >> 6) & 0x3f), u8(0x80 | r & 0x3f)]
	}
	return [u8(0xf0 | r >> 18), u8(0x80 | (r >> 12) & 0x3f), u8(0x80 | (r >> 6) & 0x3f),
		u8(0x80 | r & 0x3f)]
}

fn utf8_ok(b []u8) bool {
	return valid_utf8(b.data, b.len)
}

fn test_valid_utf8_every_scalar_value() {
	for r := u32(0); r <= 0x10ffff; r++ {
		b := encode(r)
		surrogate := r >= 0xd800 && r <= 0xdfff
		assert utf8_ok(b) == !surrogate, 'U+${r:04X}'
		// also inside an ASCII run, so the 8-byte path hands over correctly
		if r % 4099 == 0 {
			mut s := 'abcdefghij'.bytes()
			s << b
			s << 'klmnopqrstuv'.bytes()
			assert utf8_ok(s) == !surrogate
		}
	}
}

fn test_valid_utf8_rejects_malformed() {
	bad := [
		[u8(0x80)], // lone continuation
		[u8(0xc0), 0x80], // overlong NUL
		[u8(0xc1), 0xbf],
		[u8(0xe0), 0x80, 0x80], // overlong
		[u8(0xf0), 0x80, 0x80, 0x80],
		[u8(0xf4), 0x90, 0x80, 0x80], // past U+10FFFF
		[u8(0xf5), 0x80, 0x80, 0x80],
		[u8(0xff)],
		[u8(0xc3)], // truncated
		[u8(0xe2), 0x82],
		[u8(0xf0), 0x9f, 0x98],
		[u8(0xe2), 0x28, 0xa1], // bad continuation
	]
	for b in bad {
		assert !utf8_ok(b), b.hex()
	}
	// truncated after an 8-byte ASCII run
	mut s := '01234567'.bytes()
	s << [u8(0xce), 0xba, 0xe1, 0xbd, 0xb9, 0xcf]
	assert !utf8_ok(s)
	assert utf8_ok([]u8{})
	assert utf8_ok('κόσμε, ascii and 😀'.bytes())
}

fn test_unmask_round_trips_every_length() {
	mask := [u8(0x12), 0x34, 0x56, 0x78]
	for n in 0 .. 40 {
		src := noise(n, u32(n + 7))
		mut b := src.clone()
		ws_unmask(b.data, n, mask.data)
		for i in 0 .. n {
			assert b[i] == src[i] ^ mask[i & 3]
		}
		ws_unmask(b.data, n, mask.data)
		assert b == src
	}
}

fn test_frame_header_lengths() {
	for n in [0, 125, 126, 65535, 65536] {
		mut out := []u8{}
		p := []u8{len: n, init: u8(index)}
		ws_frame(mut out, ws_binary, p.data, n)
		assert out[0] == 0x82
		h := if n < 126 {
			2
		} else if n < 65536 {
			4
		} else {
			10
		}
		assert out.len == h + n, 'length ${n}'
		assert out[h..] == p
	}
	mut out := []u8{}
	ws_close_frame(mut out, 1000, 'r'.repeat(200))
	assert out[1] == 125 && out[2] == 0x03 && out[3] == 0xe8
	out.clear()
	ws_close_frame(mut out, 0, 'ignored')
	assert out == [u8(0x88), 0]
}
