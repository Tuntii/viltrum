module http1

fn parse_msg(raw string) !Head {
	buf := raw.bytes()
	mut f := Frame{}
	n := frame(buf, mut f, Limits{})!
	if n < 0 {
		return error('incomplete')
	}
	mut h := Head{}
	parse_head(buf, f.head_end, mut h)!
	return h
}

fn span_str(raw string, s Span) string {
	return raw.bytes()[s.start..s.start + s.len].bytestr()
}

fn test_request_line() {
	raw := 'GET /hi/there?x=1&y=2 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: t\r\n\r\n'
	h := parse_msg(raw)!
	assert h.method == .get
	assert span_str(raw, h.path) == '/hi/there'
	assert span_str(raw, h.query) == 'x=1&y=2'
	assert h.minor == 1
	assert h.nfields == 2
	assert span_str(raw, h.fields[1].name) == 'User-Agent'
	assert span_str(raw, h.fields[1].value) == 't'
	assert h.host_seen && h.keep_alive
}

fn test_targets() {
	abs := 'GET http://example.com/a/b?q=1 HTTP/1.1\r\nHost: x\r\n\r\n'
	h := parse_msg(abs)!
	assert span_str(abs, h.path) == '/a/b'
	assert span_str(abs, h.query) == 'q=1'
	bare := 'GET HTTPS://example.com HTTP/1.1\r\nHost: x\r\n\r\n'
	hb := parse_msg(bare)!
	assert hb.path.len == 0 && hb.query.len == 0
	star := 'OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n'
	hs := parse_msg(star)!
	assert hs.method == .options && span_str(star, hs.path) == '*'
	assert parse_msg('GET /x HTTP/1.1\r\nHost: x\r\n\r\n')!.query.len == 0
	assert method_of('PATCH') == .patch && method_of('get') == .other
		&& method_of('PURGE') == .other
}

fn test_keep_alive_rules() {
	assert parse_msg('GET / HTTP/1.1\r\nHost: x\r\n\r\n')!.keep_alive
	assert !parse_msg('GET / HTTP/1.1\r\nHost: x\r\nConnection: Close\r\n\r\n')!.keep_alive
	assert !parse_msg('GET / HTTP/1.0\r\n\r\n')!.keep_alive
	assert parse_msg('GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n')!.keep_alive
	assert parse_msg('GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, Upgrade\r\n\r\n')!.keep_alive
	assert !parse_msg('GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade,close\r\n\r\n')!.keep_alive
}

fn test_unsupported_version_is_505() {
	parse_msg('GET / HTTP/2.0\r\n\r\n') or {
		assert err.code() == 505
		return
	}
	assert false, 'HTTP/2.0 accepted'
}

fn test_too_many_fields_is_431() {
	mut raw := 'GET / HTTP/1.1\r\nHost: x\r\n'
	for i in 0 .. 32 {
		raw += 'X-${i}: v\r\n'
	}
	parse_msg(raw + '\r\n') or {
		assert err.code() == 431
		return
	}
	assert false, '33 fields accepted'
}

fn test_exactly_max_fields_is_accepted() {
	mut raw := 'GET / HTTP/1.1\r\nHost: x\r\n'
	for i in 1 .. max_fields {
		raw += 'X-${i}: v\r\n'
	}
	h := parse_msg(raw + '\r\n')!
	assert h.nfields == max_fields
}

// The positive control for every zero-allocation assert: allocated_bytes does see
// an allocation.
fn test_allocated_bytes_sees_an_allocation() {
	before := allocated_bytes()
	mut keep := [][]u8{}
	for _ in 0 .. 100 {
		keep << []u8{len: 1024}
	}
	assert allocated_bytes() - before >= 100 * 1024
	assert keep.len == 100
}

fn test_parse_allocates_nothing() {
	buf :=
		'GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: wrk\r\nAccept: */*\r\nConnection: keep-alive\r\n\r\n'.bytes()
	mut f := Frame{}
	n := frame(buf, mut f, Limits{})!
	assert n == buf.len
	mut h := Head{}
	before := allocated_bytes()
	for _ in 0 .. 10000 {
		parse_head(buf, f.head_end, mut h) or { panic(err) }
	}
	assert allocated_bytes() - before == 0
}
