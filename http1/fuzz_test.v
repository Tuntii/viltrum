module http1

import os
import rand

fn frame_and_parse(b []u8) !Head {
	mut f := Frame{}
	n := frame(b, mut f, Limits{})!
	if n < 0 {
		return error('incomplete')
	}
	mut h := Head{}
	parse_head(b, f.head_end, mut h)!
	return h
}

// Framing a front proxy might read differently than we do. Every case must be
// refused (the engine answers 4xx and closes), never silently "fixed".
fn test_rejects_ambiguous_framing() {
	bad := [
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length : 5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhelloo',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5abc\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0x5\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: \r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4294967301\r\n\r\nhello',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999999\r\n\r\nhello',
		'GET / HTTP/1.1\r\nHost: x\r\n folded: value\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\nContent-Length: 5\r\n\r\nhello',
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\rb\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX: a\x00b\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX(y): z\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding : chunked\r\n\r\n',
		'GET /a\nb HTTP/1.1\r\nHost: x\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
		'POST / HTTP/1.0\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0x5\r\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n000000005\r\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloX0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5 x\x00\r\nhello\r\n0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nBad Trailer\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n',
		' GET / HTTP/1.1\r\nHost: x\r\n\r\n',
		'GET  / HTTP/1.1\r\nHost: x\r\n\r\n',
		'GET / HTTP/1.1 \r\nHost: x\r\n\r\n',
		'G(T / HTTP/1.1\r\nHost: x\r\n\r\n',
		'GET foo HTTP/1.1\r\nHost: x\r\n\r\n',
	]
	for raw in bad {
		if _ := frame_and_parse(raw.bytes()) {
			assert false, 'accepted: ${raw.replace('\r', '\\r').replace('\n', '\\n')}'
		}
	}
}

fn test_accepts_well_formed_edges() {
	ok := [
		'GET / HTTP/1.1\r\nHost: x\r\nX-Tab:\tv\t\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 005\r\n\r\nhello',
		"GET / HTTP/1.1\r\nHost: x\r\nX-Ok!#$%&'*+-.^_`|~: v\r\n\r\n",
		'GET / HTTP/1.1\r\nHost: x\r\nX-Utf8: caf\xc3\xa9\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: x\r\nX-Empty:\r\n\r\n',
	]
	for raw in ok {
		frame_and_parse(raw.bytes()) or { assert false, '${raw}: ${err.msg()}' }
	}
}

const fuzz_seeds = [
	'GET /hi/tunay?x=1 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: t\r\n\r\n',
	'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello',
	'OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n',
	'GET http://x/a/../b?q HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
	'POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\nX-T: 1\r\n\r\n',
]

const fuzz_tokens = [':', ' ', '\t', '\r', '\n', '\r\n', '\r\n\r\n', '\x00', '\xff', ',',
	'Content-Length: ', 'Transfer-Encoding: ', 'Host: ', 'Connection: close', '%', '?', '/../',
	'-1', '4294967296', 'HTTP/1.1', 'HTTP/1.0', ';', '0\r\n\r\n']

// Random mutations over seed requests. Invariants: no panic (V aborts on OOB), and
// every span of an accepted head lies inside the buffer.
fn test_fuzz_parse() {
	iters := os.getenv_opt('VILTRUM_FUZZ_ITERS') or { '20000' }.int()
	rand.seed([u32(0x5eed), 0x1])
	for _ in 0 .. iters {
		mut b := fuzz_seeds[rand.intn(fuzz_seeds.len) or { 0 }].bytes()
		for _ in 0 .. 1 + (rand.intn(4) or { 0 }) {
			b = mutate(b)
		}
		h := frame_and_parse(b) or { continue }
		assert h.nfields <= max_fields
		assert h.path.start + h.path.len <= b.len
		assert h.query.start + h.query.len <= b.len
		for k in 0 .. h.nfields {
			f := h.fields[k]
			assert f.name.len > 0 && f.name.start + f.name.len <= b.len
			assert f.value.start + f.value.len <= b.len
		}
	}
}

fn mutate(b []u8) []u8 {
	mut out := b.clone()
	pos := if out.len == 0 { 0 } else { rand.intn(out.len) or { 0 } }
	op := rand.intn(5) or { 0 }
	match op {
		0 {
			if out.len > 0 {
				out[pos] = u8(rand.intn(256) or { 0 })
			}
		}
		1 {
			if out.len > 0 {
				out.delete(pos)
			}
		}
		2 {
			tok := fuzz_tokens[rand.intn(fuzz_tokens.len) or { 0 }].bytes()
			out.insert(pos, tok)
		}
		3 {
			end := pos + (rand.intn(16) or { 0 })
			out = out[..pos].clone()
			out << b[if end < b.len { end } else { b.len }..]
		}
		else {
			out = out[..pos].clone()
		}
	}

	return out
}
