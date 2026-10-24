module http1

import compress.gzip as vgzip

struct Msg {
	message string
}

fn serve_once(mut c Ctx, raw []u8, f Frame, n int) {
	unsafe {
		c.out.len = 0
	}
	parse_head(raw, f.head_end, mut c.head) or { panic(err) }
	c.begin(view(raw, 0, n))
	c.set_body(view(raw, f.head_end, f.content_length))
	c.chain[0](mut c)
}

const big_msg = 'x'.repeat(600)

fn big_json(mut c Ctx) {
	c.json(200, Msg{ message: big_msg })
}

fn small_text(mut c Ctx) {
	c.text(200, 'small')
}

fn gz_run(raw string, h Handler) !Ctx {
	mut c := test_ctx(raw)!
	c.deflater = new_deflater()
	c.chain = [Handler(gzip_middleware), h]
	c.chain[0](mut c)
	return c
}

fn test_gzip_round_trips() {
	mut d := new_deflater()
	for src in ['', 'hello', '{"a":1}'.repeat(5000)] {
		packed := d.gzip(src.bytes())!
		assert vgzip.decompress(packed)!.bytestr() == src
	}
}

fn test_accepts_gzip() {
	yes := ['gzip', 'gzip, br', 'br;q=1, gzip;q=0.8', 'GZIP', '*', 'identity, *;q=0.5', 'gzip;q=1.0']
	no := ['', 'br', 'gzip;q=0', 'gzip; q=0.000, *', '*;q=0.5, gzip;q=0', '*;q=0', 'gzipx', 'x-gzip',
		'gzip;q=0\t, br']
	for v in yes {
		assert accepts_gzip(v), v
	}
	for v in no {
		assert !accepts_gzip(v), v
	}
}

fn test_compressible() {
	for t in ['text/plain; charset=utf-8', 'application/json', 'application/javascript',
		'image/svg+xml', 'application/xml', 'Text/HTML'] {
		assert compressible(t), t
	}
	for t in ['image/png', 'application/octet-stream', ''] {
		assert !compressible(t), t
	}
}

fn test_middleware_compresses_when_accepted() {
	c := gz_run('GET / HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip, br\r\n\r\n', big_json)!
	s := c.out.bytestr()
	assert s.contains('Content-Encoding: gzip\r\n')
	assert s.contains('Vary: Accept-Encoding\r\n')
	body_start := s.index('\r\n\r\n')? + 4
	body := c.out[body_start..]
	assert s.contains('Content-Length: ${body.len}\r\n')
	assert vgzip.decompress(body)!.bytestr() == '{"message":"${big_msg}"}'
}

fn test_middleware_passes_through() {
	plain := gz_run('GET / HTTP/1.1\r\nHost: h\r\n\r\n', big_json)!
	ps := plain.out.bytestr()
	assert !ps.contains('Content-Encoding') && ps.contains('Vary: Accept-Encoding\r\n')
	assert ps.ends_with('{"message":"${big_msg}"}')
	small := gz_run('GET / HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip\r\n\r\n', small_text)!
	ss := small.out.bytestr()
	assert !ss.contains('Content-Encoding') && !ss.contains('Vary') && ss.ends_with('small')
	head := gz_run('HEAD / HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip\r\n\r\n', big_json)!
	assert head.out.bytestr().ends_with('\r\n\r\n')
}

fn test_middleware_allocates_nothing() {
	raw := 'GET /j HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip, br\r\n\r\n'.bytes()
	mut f := Frame{}
	n := frame(raw, mut f, Limits{})!
	mut c := Ctx.new()
	c.out = []u8{cap: 8192}
	c.deflater = new_deflater()
	c.chain = [Handler(gzip_middleware), Handler(big_json)]
	for _ in 0 .. 100 {
		serve_once(mut c, raw, f, n)
	}
	before := allocated_bytes()
	for _ in 0 .. 5000 {
		serve_once(mut c, raw, f, n)
	}
	assert allocated_bytes() - before == 0
}
