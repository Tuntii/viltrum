module engine

import net
import net.mbedtls
import os
import time
import viltrum.http1
import viltrum.router

const tls_testdata = os.join_path(os.dir(@FILE), 'testdata', 'tls')
const big_body = 'b'.repeat(5 * 1024 * 1024)

// cleartext marks a cleartext listener in start_tls.
const cleartext = TlsOptions{}

fn h_path(mut c http1.Ctx) {
	c.text(200, c.path())
}

fn h_echo(mut c http1.Ctx) {
	c.bytes(200, 'application/octet-stream', c.body())
}

fn h_big(mut c http1.Ctx) {
	c.text(200, big_body)
}

fn ws_echo(mut s http1.Ws, m http1.WsMessage) {
	if m.binary {
		s.send_binary(m.data)
	} else {
		s.send_text(m.text())
	}
}

const ws_h = &http1.WsHandler{
	on_message: ws_echo
}

fn h_ws(mut c http1.Ctx) {
	c.ws_upgrade(ws_h)
}

const file_body = 'f'.repeat(3 * 1024 * 1024) + 'end'
const file_path = os.join_path(os.temp_dir(), 'viltrum-tls-${os.getpid()}.bin')

fn h_file(mut c http1.Ctx) {
	c.file(file_path)
}

fn make_router() &router.Router {
	mut r := &router.Router{}
	r.add(.get, '/file', [http1.Handler(h_file)]) or { panic(err) }
	r.add(.get, '/p/*rest', [http1.Handler(h_path)]) or { panic(err) }
	r.add(.get, '/ws', [http1.Handler(h_ws)]) or { panic(err) }
	r.add(.post, '/echo', [http1.Handler(h_echo)]) or { panic(err) }
	r.add(.get, '/big', [http1.Handler(h_big)]) or { panic(err) }
	return r
}

fn tls_opts(dir string, name string) TlsOptions {
	return TlsOptions{
		cert_file: os.join_path(dir, '${name}.crt')
		key_file:  os.join_path(dir, '${name}.key')
	}
}

fn free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	a := l.addr() or { panic(err) }
	s := a.str()
	l.close() or {}
	return s
}

// start_tls serves one listener per entry (cleartext for an empty TlsOptions) and
// returns their addresses.
fn start_tls(kinds []TlsOptions, opts Options) ([]string, &Stop) {
	mut stop := new_stop()
	o := Options{
		...opts
		workers:        2
		handle_signals: false
		stop:           stop
		send_date:      false
	}
	mut addrs := []string{}
	mut ls := []Listener{}
	for k in kinds {
		a := free_addr()
		addrs << a
		if k.cert_file == '' {
			ls << Listener{
				addr: a
			}
		} else {
			ls << Listener{
				addr: a
				tls:  k
			}
		}
	}
	r := make_router()
	spawn fn [ls, r, o] () {
		serve_listeners(ls, r, o) or { eprintln(err) }
	}()
	for a in addrs {
		for _ in 0 .. 100 {
			mut c := net.dial_tcp(a) or {
				time.sleep(20 * time.millisecond)
				continue
			}
			c.close() or {}
			break
		}
	}
	time.sleep(50 * time.millisecond)
	return addrs, stop
}

fn dial(addr string) &net.TcpConn {
	mut c := net.dial_tcp(addr) or { panic(err) }
	c.set_read_timeout(10 * time.second)
	return c
}

fn tls_dial(addr string) &mbedtls.SSLConn {
	mut s := mbedtls.new_ssl_conn(mbedtls.SSLConnectConfig{
		validate:       false
		alpn_protocols: ['http/1.1']
	}) or { panic(err) }
	s.dial('127.0.0.1', addr.all_after_last(':').int()) or { panic(err) }
	return s
}

fn head_end(b []u8) int {
	for i := 0; i + 3 < b.len; i++ {
		if b[i] == `\r` && b[i + 1] == `\n` && b[i + 2] == `\r` && b[i + 3] == `\n` {
			return i
		}
	}
	return -1
}

// parse_response splits one Content-Length response off the front of buf:
// (status, body, bytes used), with used -1 while buf does not hold all of it.
fn parse_response(buf []u8) (int, string, int) {
	he := head_end(buf)
	if he < 0 {
		return 0, '', -1
	}
	head := buf[..he].bytestr()
	mut clen := 0
	for line in head.split('\r\n') {
		if line.to_lower().starts_with('content-length:') {
			clen = line.all_after(':').trim_space().int()
		}
	}
	end := he + 4 + clen
	if buf.len < end {
		return 0, '', -1
	}
	return head.all_after(' ').all_before(' ').int(), buf[he + 4..end].bytestr(), end
}

// TlsReader buffers a TLS client's reads so pipelined responses can be split.
struct TlsReader {
mut:
	buf []u8
	tmp []u8 = []u8{len: 64 * 1024}
}

// response reads one response with a Content-Length body: (status, body).
fn (mut r TlsReader) response(mut s mbedtls.SSLConn) !(int, string) {
	for {
		st, body, used := parse_response(r.buf)
		if used >= 0 {
			r.buf = r.buf[used..].clone()
			return st, body
		}
		n := s.read(mut r.tmp)!
		if n <= 0 {
			return error('eof')
		}
		r.buf << r.tmp[..n]
	}
	return error('unreachable')
}

// PlainReader is TlsReader for a cleartext connection.
struct PlainReader {
mut:
	buf []u8
	tmp []u8 = []u8{len: 64 * 1024}
}

fn (mut r PlainReader) response(mut c net.TcpConn) !(int, string) {
	for {
		st, body, used := parse_response(r.buf)
		if used >= 0 {
			r.buf = r.buf[used..].clone()
			return st, body
		}
		n := c.read(mut r.tmp)!
		if n <= 0 {
			return error('eof')
		}
		r.buf << r.tmp[..n]
	}
	return error('unreachable')
}

fn have_openssl() bool {
	return os.execute('openssl version').exit_code == 0
}

// served_fingerprint is the SHA-256 fingerprint of the certificate addr presents.
fn served_fingerprint(addr string) string {
	r :=
		os.execute('echo | openssl s_client -connect ${addr} 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null')
	return r.output.trim_space()
}

fn file_fingerprint(path string) string {
	return os.execute('openssl x509 -in ${path} -noout -fingerprint -sha256').output.trim_space()
}

fn test_tls_request_and_alpn() {
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	mut s := tls_dial(addrs[0])
	assert s.negotiated_alpn() == 'http/1.1'
	s.write_string('GET /p/hello HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	mut r := TlsReader{}
	status, body := r.response(mut s) or { panic(err) }
	assert status == 200
	assert body == '/p/hello'
	// keep-alive: a second request on the same session
	s.write_string('GET /p/again HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	status2, body2 := r.response(mut s) or { panic(err) }
	assert status2 == 200 && body2 == '/p/again'
	s.close() or {}
}

// Many records each way: a pipelined burst around a 5 MB response, read late so the
// server's writes stop part way through records.
fn test_tls_pipelined_burst_and_partial_writes() {
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	mut s := tls_dial(addrs[0])
	s.write_string('GET /p/1 HTTP/1.1\r\nHost: x\r\n\r\nGET /big HTTP/1.1\r\nHost: x\r\n\r\nGET /p/3 HTTP/1.1\r\nHost: x\r\n\r\n') or {
		panic(err)
	}
	time.sleep(300 * time.millisecond)
	mut r := TlsReader{}
	st1, b1 := r.response(mut s) or { panic(err) }
	assert st1 == 200 && b1 == '/p/1'
	st2, b2 := r.response(mut s) or { panic(err) }
	assert st2 == 200 && b2.len == big_body.len && b2 == big_body
	st3, b3 := r.response(mut s) or { panic(err) }
	assert st3 == 200 && b3 == '/p/3'
	s.close() or {}
}

fn test_tls_echo_bodies() {
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	mut s := tls_dial(addrs[0])
	mut r := TlsReader{}
	for size in [0, 1, 1024, 10240, 102400] {
		body := 'e'.repeat(size)
		s.write_string('POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: ${size}\r\n\r\n${body}') or {
			panic(err)
		}
		st, got := r.response(mut s) or { panic(err) }
		assert st == 200
		assert got == body, 'content-length ${size}'
	}
	// chunked, in 4 KB chunks
	body := 'c'.repeat(102400)
	mut req := 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n'
	for i := 0; i < body.len; i += 4096 {
		end := if i + 4096 > body.len { body.len } else { i + 4096 }
		part := body[i..end]
		req += '${part.len:x}\r\n${part}\r\n'
	}
	req += '0\r\n\r\n'
	s.write_string(req) or { panic(err) }
	st, got := r.response(mut s) or { panic(err) }
	assert st == 200 && got == body
	s.close() or {}
}

// A plaintext request to the TLS port is a failed handshake, never a cleartext answer.
fn test_plaintext_to_tls_port_gets_no_http() {
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	mut c := dial(addrs[0])
	c.write_string('GET /p/x HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	mut buf := []u8{len: 4096}
	mut got := []u8{}
	for {
		n := c.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		got << buf[..n]
	}
	assert !got.bytestr().starts_with('HTTP/')
	c.close() or {}
}

fn test_tls_handshake_times_out() {
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{
		read_timeout: 300 * time.millisecond
	})
	defer {
		stop.request()
	}
	mut c := dial(addrs[0])
	t0 := time.now()
	mut buf := []u8{len: 64}
	n := c.read(mut buf) or { 0 }
	assert n == 0
	assert time.since(t0) < 3 * time.second
	c.close() or {}
}

fn test_cleartext_and_tls_side_by_side() {
	addrs, mut stop := start_tls([cleartext, tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	mut c := dial(addrs[0])
	c.write_string('GET /p/plain HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	mut rd := PlainReader{}
	st, body := rd.response(mut c) or { panic(err) }
	assert st == 200 && body == '/p/plain'
	c.close() or {}
	mut s := tls_dial(addrs[1])
	s.write_string('GET /p/secure HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	mut r := TlsReader{}
	st2, body2 := r.response(mut s) or { panic(err) }
	assert st2 == 200 && body2 == '/p/secure'
	s.close() or {}
}

fn test_bad_certificate_fails_at_startup() {
	r := make_router()
	serve_listeners([
		Listener{
			addr: free_addr()
			tls:  TlsOptions{
				cert_file: os.join_path(tls_testdata, 'a.crt')
				key_file:  os.join_path(tls_testdata, 'b.key')
			}
		},
	], r, Options{ handle_signals: false }) or {
		assert err.msg().contains('is not the key of')
		return
	}
	assert false, 'serve_listeners accepted a mismatched pair'
}

fn tls_roundtrips(mut s mbedtls.SSLConn, req string, want int, mut buf []u8, n int) {
	for _ in 0 .. n {
		s.write_ptr(req.str, req.len) or { panic(err) }
		mut got := 0
		for got < want {
			got += s.socket_read_into_ptr(unsafe { &u8(buf.data) + got }, buf.len - got) or {
				panic(err)
			}
		}
	}
}

// Once buffers are warm, requests over a TLS session allocate nothing on the GC heap.
fn test_tls_hot_path_allocates_nothing() {
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	mut s := tls_dial(addrs[0])
	req := 'GET /p/zero HTTP/1.1\r\nHost: x\r\n\r\n'
	want := 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 7\r\n\r\n/p/zero'
	mut buf := []u8{len: 4096}
	tls_roundtrips(mut s, req, want.len, mut buf, 200)
	before := http1.allocated_bytes()
	tls_roundtrips(mut s, req, want.len, mut buf, 2000)
	assert http1.allocated_bytes() - before == 0
	assert unsafe { tos(buf.data, want.len) } == want
	s.close() or {}
}

fn test_tls_versions_and_close_notify() {
	if !have_openssl() {
		eprintln('skip: openssl not found')
		return
	}
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	a := addrs[0]
	v13 := os.execute('echo | openssl s_client -connect ${a} -tls1_3 2>&1')
	assert v13.output.contains('TLSv1.3'), v13.output
	v12 := os.execute('echo | openssl s_client -connect ${a} -tls1_2 2>&1')
	assert v12.output.contains('TLSv1.2'), v12.output
	assert v12.output.contains('GCM') || v12.output.contains('CHACHA20'), v12.output
	v11 := os.execute('echo | openssl s_client -connect ${a} -tls1_1 2>&1')
	assert !v11.output.contains('Protocol  : TLSv1.1'), v11.output
	alpn := os.execute('echo | openssl s_client -connect ${a} -alpn h2,http/1.1 2>&1')
	assert alpn.output.contains('ALPN protocol: http/1.1'), alpn.output
	no_sni := os.execute('echo | openssl s_client -connect ${a} -noservername 2>&1')
	assert no_sni.output.contains('TLSv1.3'), no_sni.output
	// close_notify before EOF: openssl reports "unexpected eof" without it
	closing :=
		os.execute('printf "GET /p/bye HTTP/1.1\\r\\nHost: x\\r\\nConnection: close\\r\\n\\r\\n" | openssl s_client -connect ${a} -quiet -ign_eof 2>&1')
	assert closing.output.contains('/p/bye'), closing.output
	assert !closing.output.contains('unexpected eof'), closing.output
}

// A pair rename-swapped on disk is served on new handshakes within a couple of
// seconds; a half-swapped pair (new cert, old key) is never served; a session opened
// before the swap keeps working.
fn test_certificate_reload() {
	if !have_openssl() {
		eprintln('skip: openssl not found')
		return
	}
	dir := os.join_path(os.temp_dir(), 'viltrum-tls-${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	for ext in ['crt', 'key'] {
		os.cp(os.join_path(tls_testdata, 'a.${ext}'), os.join_path(dir, 'server.${ext}')) or {
			panic(err)
		}
	}
	addrs, mut stop := start_tls([tls_opts(dir, 'server')], Options{})
	defer {
		stop.request()
	}
	a := addrs[0]
	fa := file_fingerprint(os.join_path(tls_testdata, 'a.crt'))
	fb := file_fingerprint(os.join_path(tls_testdata, 'b.crt'))
	assert fa != '' && fa != fb
	assert served_fingerprint(a) == fa
	mut s := tls_dial(a)
	mut r := TlsReader{}
	// half swap: the new certificate next to the old key
	os.cp(os.join_path(tls_testdata, 'b.crt'), os.join_path(dir, 'next.crt')) or { panic(err) }
	os.rename(os.join_path(dir, 'next.crt'), os.join_path(dir, 'server.crt')) or { panic(err) }
	time.sleep(1500 * time.millisecond)
	assert served_fingerprint(a) == fa
	// complete the swap
	os.cp(os.join_path(tls_testdata, 'b.key'), os.join_path(dir, 'next.key')) or { panic(err) }
	os.rename(os.join_path(dir, 'next.key'), os.join_path(dir, 'server.key')) or { panic(err) }
	mut served := ''
	for _ in 0 .. 30 {
		served = served_fingerprint(a)
		if served == fb {
			break
		}
		time.sleep(200 * time.millisecond)
	}
	assert served == fb
	s.write_string('GET /p/still HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
	st, body := r.response(mut s) or { panic(err) }
	assert st == 200 && body == '/p/still'
	s.close() or {}
}

// wss: the same WebSocket frames over a TLS session, messages spanning records.
fn test_websocket_over_tls() {
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	mut s := tls_dial(addrs[0])
	s.write_string('GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n') or {
		panic(err)
	}
	mut buf := []u8{}
	mut tmp := []u8{len: 64 * 1024}
	for head_end(buf) < 0 {
		n := s.read(mut tmp) or { panic(err) }
		buf << tmp[..n]
	}
	he := head_end(buf)
	assert buf[..he].bytestr().starts_with('HTTP/1.1 101 ')
	buf = buf[he + 4..].clone()
	// one 100 KB binary message, unmasked with an all-zero mask
	msg := []u8{len: 100 * 1024, init: u8(index * 31)}
	mut f := [u8(0x82), 0x80 | 127, 0, 0, 0, 0, 0, u8(msg.len >> 16), u8(msg.len >> 8), u8(msg.len),
		0, 0, 0, 0]
	f << msg
	s.write(f) or { panic(err) }
	for buf.len < 10 + msg.len {
		n := s.read(mut tmp) or { panic(err) }
		buf << tmp[..n]
	}
	assert buf[0] == 0x82 && buf[1] == 127 && buf[10..10 + msg.len] == msg
	s.write([u8(0x88), 0x82, 0, 0, 0, 0, 0x03, 0xe8]) or { panic(err) }
	buf = buf[10 + msg.len..].clone()
	for buf.len < 4 {
		n := s.read(mut tmp) or { panic(err) }
		buf << tmp[..n]
	}
	assert buf[..4] == [u8(0x88), 2, 0x03, 0xe8]
	s.close() or {}
}

// openssl_session pipes script into `openssl s_client` against addr and returns what
// it printed. The script is shell: printf requests, sleep, and s_client's K / k lines.
fn openssl_session(addr string, args string, script string) string {
	r := os.execute('(${script}) | timeout 10 openssl s_client -connect ${addr} ${args} 2>&1')
	return r.output.replace('\r', '')
}

const echo_req = 'printf "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n\r\nhello\n"'

// echo_last asks the server to close after answering, so s_client ends there
const echo_last = 'printf "POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 6\r\n\r\nhello\n"'

// TLS 1.3 with AES-GCM moves to tls13 after the handshake. mbedtls answers a client's
// KeyUpdate with an error, so this passing is also what shows the move happened.
fn test_tls13_records_with_openssl() {
	if !have_openssl() || !aesgcm_supported {
		eprintln('skipped: needs openssl and an AES-NI/PCLMUL build')
		return
	}
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	// K: the client updates and asks us to update as well; k: it only updates
	for cmd in ['K', 'k'] {
		out := openssl_session(addrs[0], '-tls1_3',
			'${echo_req}; sleep 0.3; echo ${cmd}; sleep 0.3; ${echo_req}; sleep 0.3; echo ${cmd}; sleep 0.3; ${echo_last}; sleep 0.5')
		assert out.count('KEYUPDATE') == 2, out
		assert out.count('\nhello\n') == 3, out
	}
	// every TLS 1.3 suite, and TLS 1.2, which stays on mbedtls
	for args in ['-tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256',
		'-tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384',
		'-tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256', '-tls1_2'] {
		out := openssl_session(addrs[0], '${args} -quiet -ign_eof', '${echo_last}; sleep 0.4')
		assert out.ends_with('hello\n'), '${args}: ${out}'
	}
}

// Over TLS a streamed file goes through wbuf one buffer at a time.
fn test_tls_file_is_streamed_in_order() {
	os.write_file(file_path, file_body) or { panic(err) }
	defer {
		os.rm(file_path) or {}
	}
	addrs, mut stop := start_tls([tls_opts(tls_testdata, 'a')], Options{})
	defer {
		stop.request()
	}
	mut s := tls_dial(addrs[0])
	s.write_string('GET /file HTTP/1.1\r\nHost: x\r\n\r\nGET /file HTTP/1.1\r\nHost: x\r\nRange: bytes=1-2\r\n\r\nGET /p/3 HTTP/1.1\r\nHost: x\r\n\r\n') or {
		panic(err)
	}
	time.sleep(300 * time.millisecond)
	mut r := TlsReader{}
	st1, b1 := r.response(mut s) or { panic(err) }
	assert st1 == 200 && b1.len == file_body.len && b1 == file_body
	st2, b2 := r.response(mut s) or { panic(err) }
	assert st2 == 206 && b2 == 'ff'
	st3, b3 := r.response(mut s) or { panic(err) }
	assert st3 == 200 && b3 == '/p/3'
	s.close() or {}
}
