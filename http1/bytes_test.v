module http1

fn test_append_int_matches_str() {
	mut out := []u8{cap: 64}
	for n in [i64(0), 7, -7, 10, 99, 100, 1234567890, -9223372036854775807 - 1, 9223372036854775807] {
		unsafe {
			out.len = 0
		}
		append_int(mut out, n)
		assert out.bytestr() == n.str()
	}
}

fn test_put_spare_full_and_slice() {
	mut out := []u8{cap: 8}
	put(mut out, c'abc', 3) // spare capacity
	put(mut out, c'defghij', 7) // past cap: grows
	put(mut out, c'x', 0)
	assert out.bytestr() == 'abcdefghij'
	// a slice shares its parent's block: appending must not write into the parent
	mut parent := 'abcdef'.bytes()
	parent << `g` // leave spare capacity behind the slice
	mut s := unsafe { parent[..2] } // a real slice: a plain `mut s := parent[..2]` is a clone
	unsafe {
		s.cap = 4 // V gives slices cap == len; spare room would make put write into parent
	}
	put(mut s, c'XY', 2)
	assert s.bytestr() == 'abXY'
	assert parent.bytestr() == 'abcdefg'
}

fn test_views_share_memory() {
	buf := 'GET /abc HTTP/1.1'.bytes()
	v := view(buf, 4, 4)
	assert v.bytestr() == '/abc'
	assert unsafe { &u8(v.data) } == unsafe { &u8(buf.data) + 4 }
	s := str_view(buf, 4, 4)
	assert s == '/abc'
	assert s.str == unsafe { &u8(buf.data) + 4 }
	assert str_view(buf, 0, 0) == ''
}

fn test_case_and_tokens() {
	assert eq_ci('Content-Length', 'content-length')
	assert !eq_ci('Content-Lengt', 'content-length')
	assert lower(`A`) == `a` && lower(`z`) == `z` && lower(`-`) == `-`
	for c in "!#$%&'*+-.^_`|~09azAZ".bytes() {
		assert is_tchar(c)
	}
	for c in ' \t"(),/:;<=>?@[\\]{}\x7f\x00'.bytes() {
		assert !is_tchar(c)
	}
}

fn test_parse_i64() {
	assert parse_i64('42')? == 42
	assert parse_i64(' -17 ')? == -17
	assert parse_i64('+5')? == 5
	assert parse_i64('20\r\n')? == 20
	for bad in ['', ' ', '-', '1x', '0x10', '1234567890123456789'] {
		if _ := parse_i64(bad) {
			assert false, bad
		}
	}
}

fn test_helpers_allocate_nothing() {
	buf := 'GET /abc HTTP/1.1'.bytes()
	mut out := []u8{cap: 4096}
	before := allocated_bytes()
	for i in 0 .. 10000 {
		unsafe {
			out.len = 0
		}
		append_str(mut out, str_view(buf, 0, 3))
		append_bytes(mut out, view(buf, 4, 4))
		append_int(mut out, i64(i))
		_ = eq_ci(str_view(buf, 9, 8), 'http/1.1')
		_ = parse_i64(str_view(buf, 5, 3)) or { 0 }
	}
	assert allocated_bytes() - before == 0
}
