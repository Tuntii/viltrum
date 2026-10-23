module main

import os
import viltrum

// A served tree:
//   root/hello.txt, root/app.css, root/big.bin (past file_inline_max), root/.env,
//   root/docs/index.html, root/empty/ (no index), root/z.txt (empty)
// and outside it: secret.txt, which no URL may reach.
fn make_tree() (string, string) {
	base := os.join_path(os.temp_dir(), 'viltrum-static-${os.getpid()}')
	root := os.join_path(base, 'root')
	os.rmdir_all(base) or {}
	os.mkdir_all(os.join_path(root, 'docs')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'empty')) or { panic(err) }
	os.write_file(os.join_path(root, 'hello.txt'), 'hello, static\n') or { panic(err) }
	os.write_file(os.join_path(root, 'app.css'), 'body{margin:0}'.repeat(100)) or { panic(err) }
	os.write_file(os.join_path(root, 'big.bin'), big_body()) or { panic(err) }
	os.write_file(os.join_path(root, '.env'), 'SECRET=1') or { panic(err) }
	os.write_file(os.join_path(root, 'docs', 'index.html'), '<h1>docs</h1>') or { panic(err) }
	os.write_file(os.join_path(root, 'z.txt'), '') or { panic(err) }
	os.write_file(os.join_path(base, 'secret.txt'), 'top secret') or { panic(err) }
	return base, root
}

fn big_body() string {
	mut b := []u8{len: 200 * 1024 + 7}
	for i in 0 .. b.len {
		b[i] = u8(`a` + i % 26)
	}
	return b.bytestr()
}

fn get(a &viltrum.App, path string, extra string) string {
	return a.handle_raw('GET ${path} HTTP/1.1\r\nHost: x\r\n${extra}\r\n') or { panic(err) }
}

fn header(resp string, name string) string {
	for line in resp.all_before('\r\n\r\n').split('\r\n') {
		if line.to_lower().starts_with(name.to_lower() + ': ') {
			return line.all_after(': ')
		}
	}
	return ''
}

fn body(resp string) string {
	return resp.all_after('\r\n\r\n')
}

fn status(resp string) int {
	return resp.all_after('HTTP/1.1 ').all_before(' ').int()
}

fn static_app(root string, opts viltrum.StaticOptions) &viltrum.App {
	mut a := viltrum.new()
	a.use(viltrum.gzip)
	a.static_files('/assets', root, opts)
	a.get('/report', fn [root] (mut c viltrum.Ctx) {
		c.file(os.join_path(root, 'hello.txt'), content_type: 'text/x-report', max_age: 60)
	})
	return a
}

fn test_get_and_head() {
	base, root := make_tree()
	defer {
		os.rmdir_all(base) or {}
	}
	a := static_app(root, viltrum.StaticOptions{})
	r := get(a, '/assets/hello.txt', '')
	assert status(r) == 200
	assert body(r) == 'hello, static\n'
	assert header(r, 'content-type') == 'text/plain; charset=utf-8'
	assert header(r, 'content-length') == '14'
	assert header(r, 'accept-ranges') == 'bytes'
	assert header(r, 'etag').starts_with('"') && header(r, 'etag').ends_with('"')
	assert header(r, 'last-modified').ends_with(' GMT')
	assert header(r, 'cache-control') == ''
	h := a.handle_raw('HEAD /assets/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n')!
	assert status(h) == 200 && header(h, 'content-length') == '14' && body(h) == ''
	assert header(h, 'etag') == header(r, 'etag')
	// an empty file
	z := get(a, '/assets/z.txt', '')
	assert status(z) == 200 && header(z, 'content-length') == '0' && body(z) == ''
	// gzip is registered, but a file answer is never captured or compressed
	css := get(a, '/assets/app.css', 'Accept-Encoding: gzip\r\n')
	assert status(css) == 200 && header(css, 'content-encoding') == ''
	assert header(css, 'content-type') == 'text/css; charset=utf-8' && body(css).len == 1400
	// Ctx.file from a handler, with its options
	rep := get(a, '/report', '')
	assert body(rep) == 'hello, static\n' && header(rep, 'content-type') == 'text/x-report'
	assert header(rep, 'cache-control') == 'max-age=60'
	// what the router does not match, and methods a file route does not take
	assert status(get(a, '/assets/nope.txt', '')) == 404
	p := a.handle_raw('POST /assets/hello.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n')!
	assert status(p) == 405
}

fn test_conditional_requests() {
	base, root := make_tree()
	defer {
		os.rmdir_all(base) or {}
	}
	a := static_app(root, viltrum.StaticOptions{})
	first := get(a, '/assets/hello.txt', '')
	etag := header(first, 'etag')
	lm := header(first, 'last-modified')
	for inm in [etag, 'W/${etag}', '"other", ${etag}', '*'] {
		r := get(a, '/assets/hello.txt', 'If-None-Match: ${inm}\r\n')
		assert status(r) == 304, inm
		assert body(r) == '' && header(r, 'content-length') == ''
		assert header(r, 'etag') == etag
	}
	assert status(get(a, '/assets/hello.txt', 'If-None-Match: "other"\r\n')) == 200
	assert status(get(a, '/assets/hello.txt', 'If-Modified-Since: ${lm}\r\n')) == 304
	epoch := 'If-Modified-Since: Thu, 01 Jan 1970 00:00:00 GMT\r\n'
	assert status(get(a, '/assets/hello.txt', epoch)) == 200
	assert status(get(a, '/assets/hello.txt', 'If-Modified-Since: yesterday\r\n')) == 200
	// If-None-Match decides when both are sent
	both := 'If-None-Match: "other"\r\nIf-Modified-Since: ${lm}\r\n'
	assert status(get(a, '/assets/hello.txt', both)) == 200
}

fn test_ranges() {
	base, root := make_tree()
	defer {
		os.rmdir_all(base) or {}
	}
	a := static_app(root, viltrum.StaticOptions{})
	cases := {
		'bytes=0-4':   'hello'
		'bytes=7-':    'static\n'
		'bytes=-7':    'static\n'
		'bytes=7-999': 'static\n'
		'bytes=-999':  'hello, static\n'
	}
	for rng, want in cases {
		r := get(a, '/assets/hello.txt', 'Range: ${rng}\r\n')
		assert status(r) == 206, rng
		assert body(r) == want, rng
		assert header(r, 'content-length') == want.len.str()
		assert header(r, 'content-range').ends_with('/14')
	}
	assert header(get(a, '/assets/hello.txt', 'Range: bytes=0-4\r\n'), 'content-range') == 'bytes 0-4/14'
	for rng in ['bytes=14-', 'bytes=100-200', 'bytes=-0'] {
		r := get(a, '/assets/hello.txt', 'Range: ${rng}\r\n')
		assert status(r) == 416, rng
		assert header(r, 'content-range') == 'bytes */14' && body(r) == ''
	}
	// served whole: several ranges, malformed ones, another unit
	for rng in ['bytes=0-1,3-4', 'bytes=5-2', 'bytes=x-1', 'items=0-1', 'bytes=1-2 junk'] {
		r := get(a, '/assets/hello.txt', 'Range: ${rng}\r\n')
		assert status(r) == 200 && body(r) == 'hello, static\n', rng
	}
	// If-Range: honored for the current ETag or date, ignored once the file changed
	etag := header(get(a, '/assets/hello.txt', ''), 'etag')
	lm := header(get(a, '/assets/hello.txt', ''), 'last-modified')
	assert status(get(a, '/assets/hello.txt', 'Range: bytes=0-4\r\nIf-Range: ${etag}\r\n')) == 206
	assert status(get(a, '/assets/hello.txt', 'Range: bytes=0-4\r\nIf-Range: ${lm}\r\n')) == 206
	assert status(get(a, '/assets/hello.txt', 'Range: bytes=0-4\r\nIf-Range: "old"\r\n')) == 200
	assert status(get(a, '/assets/hello.txt', 'Range: bytes=0-4\r\nIf-Range: W/${etag}\r\n')) == 200
	// HEAD never gets a partial answer
	h := a.handle_raw('HEAD /assets/hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-4\r\n\r\n')!
	assert status(h) == 200 && header(h, 'content-length') == '14'
}

fn test_large_file_is_streamed_whole() {
	base, root := make_tree()
	defer {
		os.rmdir_all(base) or {}
	}
	a := static_app(root, viltrum.StaticOptions{})
	want := big_body()
	r := get(a, '/assets/big.bin', '')
	assert status(r) == 200 && header(r, 'content-length') == want.len.str()
	assert header(r, 'content-type') == 'application/octet-stream'
	assert body(r) == want
	part := get(a, '/assets/big.bin', 'Range: bytes=100000-\r\n')
	assert status(part) == 206 && body(part) == want[100000..]
	// a request pipelined behind the streamed file is answered after all of it
	req := 'GET /assets/big.bin HTTP/1.1\r\nHost: x\r\n\r\n'
	two := a.handle_raw(req + 'GET /assets/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n')!
	idx := two.index(want) or { -1 }
	assert idx > 0
	rest := two[idx + want.len..]
	assert rest.starts_with('HTTP/1.1 200 ') && rest.ends_with('hello, static\n')
}

fn test_directories_and_index() {
	base, root := make_tree()
	defer {
		os.rmdir_all(base) or {}
	}
	a := static_app(root, viltrum.StaticOptions{})
	r := get(a, '/assets/docs/', '')
	assert status(r) == 200 && body(r) == '<h1>docs</h1>'
	assert header(r, 'content-type') == 'text/html; charset=utf-8'
	d := get(a, '/assets/docs?x=1', '')
	assert status(d) == 301 && header(d, 'location') == '/assets/docs/?x=1'
	top := get(a, '/assets', '')
	assert status(top) == 301 && header(top, 'location') == '/assets/'
	assert status(get(a, '/assets/empty/', '')) == 404
	assert status(get(a, '/assets//docs//index.html', '')) == 200
	no_index := static_app(root, viltrum.StaticOptions{ index: '' })
	assert status(get(no_index, '/assets/docs/', '')) == 404
}

fn test_nothing_outside_the_root() {
	base, root := make_tree()
	defer {
		os.rmdir_all(base) or {}
	}
	a := static_app(root, viltrum.StaticOptions{})
	for path in ['/assets/../secret.txt', '/assets/%2e%2e/secret.txt',
		'/assets/docs/%2e%2e%2f..%2fsecret.txt', '/assets/docs/..%2f..%2fsecret.txt',
		'/assets/%2E%2E/secret.txt', '/assets/./hello.txt', '/assets/hello.txt%00.png',
		'/assets/..%5csecret.txt', '/assets/%zz', '/assets/a%2', '/assets/.env', '/assets/%2eenv'] {
		r := get(a, path, '')
		assert status(r) in [400, 404], path
		assert !r.contains('top secret') && !r.contains('SECRET'), path
	}
	dot := static_app(root, viltrum.StaticOptions{ dotfiles: true })
	assert body(get(dot, '/assets/.env', '')) == 'SECRET=1'
	assert status(get(dot, '/assets/%2e%2e/secret.txt', '')) == 404
	// percent-encoded names that are fine
	os.write_file(os.join_path(root, 'a b.txt'), 'spaced') or { panic(err) }
	assert body(get(a, '/assets/a%20b.txt', '')) == 'spaced'
}

fn test_group_static_behind_middleware() {
	base, root := make_tree()
	defer {
		os.rmdir_all(base) or {}
	}
	mut a := viltrum.new()
	mut g := a.group('/v1', fn (mut c viltrum.Ctx) {
		c.set_header('X-Group', 'yes')
		c.next()
	})
	g.static_files('/files', root, max_age: 3600)
	r := get(a, '/v1/files/hello.txt', '')
	assert status(r) == 200 && header(r, 'x-group') == 'yes'
	assert header(r, 'cache-control') == 'max-age=3600'
}
