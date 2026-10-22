module http1

import rand

// The hot path trades bounds checks and passes for speed (direct_array_access,
// memchr, a table, one writer). These tests hold each fast version to the plain one
// it replaced, on generated input, so a slip shows up as a mismatch instead of a
// silent out-of-bounds read.

const pieces = ['\r\n', '\r', '\n', ':', ': ', ' ', '\t', 'a', 'X', 'c', 'T', 'e', 'Content-Length',
	'content-length:', 'Transfer-Encoding', 'transfer-encoding: chunked', 'Expect',
	'expect:100-continue', 'chunked', '5', '\r\n\r\n', 'Host: x', '\x00', '\x7f', '\xff']

fn noise_head(r int) []u8 {
	mut b := 'GET / HTTP/1.1\r\n'.bytes()
	n := rand.intn(24) or { 0 }
	for _ in 0 .. n {
		if rand.intn(8) or { 0 } == 0 {
			b << u8(rand.intn(256) or { 0 })
		} else {
			b << pieces[rand.intn(pieces.len) or { 0 }].bytes()
		}
	}
	if r % 2 == 0 {
		b << '\r\n\r\n'.bytes()
	}
	return b
}

fn ref_find_head_end(buf []u8, from int) int {
	mut i := from
	for i + 3 < buf.len {
		if buf[i] == `\r` && buf[i + 1] == `\n` && buf[i + 2] == `\r` && buf[i + 3] == `\n` {
			return i + 4
		}
		i++
	}
	return -1
}

fn ref_is_tchar(c u8) bool {
	if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) {
		return true
	}
	return match c {
		`!`, `#`, `$`, `%`, `&`, `'`, `*`, `+`, `-`, `.`, `^`, `_`, `\``, `|`, `~` { true }
		else { false }
	}
}

fn test_tchar_table() {
	for c in 0 .. 256 {
		assert is_tchar(u8(c)) == ref_is_tchar(u8(c)), 'byte ${c}'
	}
}

fn test_head_end_and_framing_fields_match_the_plain_scans() {
	iters := 100_000
	for r in 0 .. iters {
		b := noise_head(r)
		for from in [0, 1, 3, b.len / 2, b.len - 3, b.len] {
			if from < 0 || from > b.len {
				continue
			}
			assert find_head_end(b, from) == ref_find_head_end(b, from), b.hex()
		}
		mut te := Span{}
		mut cl := Span{}
		mut ex := Span{}
		framing_fields(b, mut te, mut cl, mut ex)
		assert te == header_value(b, 'transfer-encoding'), b.hex()
		assert cl == header_value(b, 'content-length'), b.hex()
		assert ex == header_value(b, 'expect'), b.hex()
	}
}

fn test_fast_writer_matches_the_slow_one() {
	statuses := [99, 100, 101, 200, 204, 301, 304, 404, 426, 500, 599, 999, 1000]
	types := ['', 'text/plain', 'bad\r\ntype']
	mut fast := Ctx.new()
	mut slow := Ctx.new()
	for r in 0 .. 20_000 {
		status := statuses[r % statuses.len]
		for x in [&fast, &slow] {
			mut c := unsafe { x }
			c.out = []u8{cap: 4096}
			c.send_date = r % 3 != 0
			c.server = if r % 5 == 0 { 'viltrum' } else { '' }
			c.close_after = r % 7 == 0
			c.head.minor = if r % 11 == 0 { 0 } else { 1 }
			c.head.method = if r % 13 == 0 { Method.head } else { Method.get }
			c.nextra = 0
			for k in 0 .. r % 4 {
				c.extra[k] = HeaderPair{'X-K${k}', 'v${r}'}
				c.nextra++
			}
		}
		body := 'b'.repeat(r % 300)
		ct := types[r % types.len]
		ce := if r % 6 == 0 { 'gzip' } else { '' }
		assert fast.write_response_fast(status, ct, ce, body.str, body.len) == (status >= 100
			&& status <= 999)
		if status < 100 || status > 999 {
			continue
		}
		slow.write_response_slow(status, ct, ce, body.str, body.len)
		assert fast.out == slow.out, 'status ${status} round ${r}'
	}
	// no room: the fast writer declines and leaves out alone
	fast.out = []u8{cap: 10}
	assert !fast.write_response_fast(200, 'text/plain', '', c'hello', 5)
	assert fast.out.len == 0
}
