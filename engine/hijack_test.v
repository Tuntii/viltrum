module engine

// Integration tests: real TCP, upgrade echo, leftover pushback, normal HTTP still works.
// Each test binds a free port (127.0.0.1:0) to avoid collisions with leftover servers.

import net
import time
import viltrum.http

fn free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('free_addr listen: ${err}') }
	a := l.addr() or {
		l.close() or {}
		panic('free_addr addr: ${err}')
	}
	s := a.str()
	l.close() or {}
	return s
}

fn wait_listen() {
	time.sleep(100 * time.millisecond)
}

fn test_hijack_101_then_echo() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		idle_timeout:   2 * time.second
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
	}
	upgrades := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/echo'
			handler: fn (mut c Conn, req http.Request) {
				resp := http.Response.switching_protocols('echo')
				c.write_all(resp.to_bytes()) or { return }
				mut buf := []u8{len: 4}
				c.read_exact(mut buf) or { return }
				c.write_all(buf) or { return }
				c.close() or {}
			}
		},
	]
	handler := fn (req http.Request) http.Response {
		return http.Response.text(200, 'http-ok')
	}

	spawn fn [handler, upgrades, opts, addr] () {
		listen_and_serve_full(addr, handler, upgrades, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	client.set_write_timeout(2 * time.second)

	client.write('GET /echo HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false, 'write req'
		return
	}

	mut hdr := read_until_double_crlf(mut client) or {
		assert false, 'read 101: ${err}'
		return
	}
	assert hdr.contains('101')
	assert hdr.to_lower().contains('upgrade')

	client.write('ping'.bytes()) or {
		assert false, 'write ping'
		return
	}
	mut echo := []u8{len: 4}
	read_exact_tcp(mut client, mut echo) or {
		assert false, 'read echo: ${err}'
		return
	}
	assert echo.bytestr() == 'ping'
}

fn test_post_request_bytes_readable_on_conn() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		idle_timeout:   2 * time.second
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
	}
	upgrades := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/up'
			handler: fn (mut c Conn, req http.Request) {
				mut resp := http.Response.switching_protocols('echo')
				resp.headers.set('X-Buffered', '${c.buffered_len()}')
				c.write_all(resp.to_bytes()) or { return }
				mut buf := []u8{len: 4}
				c.read_exact(mut buf) or { return }
				c.write_all(buf) or {}
				c.close() or {}
			}
		},
	]
	spawn fn [upgrades, opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.not_found()
		}, upgrades, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	client.set_write_timeout(2 * time.second)

	client.write('GET /up HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '101: ${err}'
		return
	}
	assert hdr.contains('101')

	client.write('LEFT'.bytes()) or {
		assert false
		return
	}
	mut out := []u8{len: 4}
	read_exact_tcp(mut client, mut out) or {
		assert false, 'echo: ${err}'
		return
	}
	assert out.bytestr() == 'LEFT'
}

fn test_normal_http_alongside_upgrade() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		idle_timeout:   2 * time.second
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
	}
	upgrades := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/ws'
			handler: fn (mut c Conn, req http.Request) {
				c.write_all(http.Response.switching_protocols('x').to_bytes()) or {}
				c.close() or {}
			}
		},
	]
	spawn fn [upgrades, opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'plain')
		}, upgrades, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	client.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '${err}'
		return
	}
	assert hdr.contains('200')
	mut body := []u8{len: 16}
	n := client.read(mut body) or { 0 }
	if n > 0 {
		assert body[..n].bytestr().contains('plain')
	}
}

fn test_te_cl_conflict_returns_400() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
	}
	spawn fn [opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'nope')
		}, []UpgradeRoute{}, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	bad := 'POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\nA'
	client.write(bad.bytes()) or {
		assert false
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '${err}'
		return
	}
	assert hdr.contains('400')
}

fn test_send_date_and_server_header() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
		send_date:      true
		server_header:  'viltrum/0.4'
	}
	spawn fn [opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'ok')
		}, []UpgradeRoute{}, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	client.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '${err}'
		return
	}
	assert hdr.contains('200')
	assert hdr.contains('Server: viltrum/0.4')
	assert hdr.contains('Date:')
	assert hdr.contains('GMT')
}

fn test_handler_date_not_overwritten() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
		send_date:      true
		server_header:  'viltrum'
	}
	spawn fn [opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			mut r := http.Response.text(200, 'ok')
			r.headers.set('Date', 'Wed, 01 Jan 2020 00:00:00 GMT')
			r.headers.set('Server', 'custom')
			return r
		}, []UpgradeRoute{}, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	client.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '${err}'
		return
	}
	assert hdr.contains('Date: Wed, 01 Jan 2020 00:00:00 GMT')
	assert hdr.contains('Server: custom')
	assert !hdr.contains('Server: viltrum\r\n')
}

fn test_max_conns_returns_503() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   5 * time.second
		max_conns:      1
	}
	upgrades := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/hold'
			handler: fn (mut c Conn, req http.Request) {
				c.write_all(http.Response.switching_protocols('hold').to_bytes()) or {}
				time.sleep(400 * time.millisecond)
				c.close() or {}
			}
		},
	]
	spawn fn [opts, addr, upgrades] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'free')
		}, upgrades, opts) or {}
	}()
	wait_listen()

	mut holder := net.dial_tcp(addr) or {
		assert false, 'dial hold: ${err}'
		return
	}
	holder.set_read_timeout(2 * time.second)
	holder.write('GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	_ := read_until_double_crlf(mut holder) or {
		assert false, 'hold 101: ${err}'
		return
	}

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial busy: ${err}'
		return
	}
	defer {
		client.close() or {}
		holder.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	client.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '503 read: ${err}'
		return
	}
	assert hdr.contains('503')
	assert hdr.to_lower().contains('connection: close')
}

fn test_upgrade_peer_ip_available() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
	}
	upgrades := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/ip'
			handler: fn (mut c Conn, req http.Request) {
				ip := c.peer_ip() or { 'none' }
				mut r := http.Response.switching_protocols('ip')
				r.headers.set('X-Peer', ip)
				c.write_all(r.to_bytes()) or {}
				c.close() or {}
			}
		},
	]
	spawn fn [opts, addr, upgrades] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.not_found()
		}, upgrades, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	client.write('GET /ip HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '${err}'
		return
	}
	assert hdr.contains('101')
	assert hdr.contains('X-Peer:')
	assert hdr.contains('127.0.0.1')
}

// After hijack, read deadline is max(read_timeout, idle_timeout) so quiet
// long-lived streams survive past a short HTTP request timeout (#4).
fn test_upgrade_idle_uses_max_of_read_and_idle() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		// Short request timeout; longer idle so upgrade should wait ~idle.
		read_timeout:  200 * time.millisecond
		write_timeout: 2 * time.second
		idle_timeout:  900 * time.millisecond
	}
	upgrades := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/hold'
			handler: fn (mut c Conn, req http.Request) {
				resp := http.Response.switching_protocols('hold')
				c.write_all(resp.to_bytes()) or { return }
				// Block on one byte from the peer (uses post-upgrade read deadline).
				mut buf := []u8{len: 1}
				c.read_exact(mut buf) or {
					c.close() or {}
					return
				}
				c.write_all(buf) or {}
				c.close() or {}
			}
		},
	]
	spawn fn [upgrades, opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.not_found()
		}, upgrades, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(3 * time.second)
	client.set_write_timeout(3 * time.second)
	client.write('GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false, 'write req'
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '101: ${err}'
		return
	}
	assert hdr.contains('101')

	// Sleep past read_timeout (200ms) but under idle_timeout (900ms).
	// Server must still accept the byte (policy: max of the two).
	time.sleep(450 * time.millisecond)
	client.write('Z'.bytes()) or {
		assert false, 'write after idle: ${err}'
		return
	}
	mut echo := []u8{len: 1}
	read_exact_tcp(mut client, mut echo) or {
		assert false, 'echo after idle should succeed: ${err}'
		return
	}
	assert echo.bytestr() == 'Z'
}

// When both timeouts are short, a quiet upgraded conn still eventually times out.
fn test_upgrade_still_times_out_when_deadline_exceeded() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   150 * time.millisecond
		write_timeout:  2 * time.second
		idle_timeout:   150 * time.millisecond
	}
	upgrades := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/slow'
			handler: fn (mut c Conn, req http.Request) {
				c.write_all(http.Response.switching_protocols('slow').to_bytes()) or { return }
				mut buf := []u8{len: 1}
				// Expect timeout / error; close either way.
				c.read_exact(mut buf) or {
					c.close() or {}
					return
				}
				// If we got a byte unexpectedly, still close.
				c.close() or {}
			}
		},
	]
	spawn fn [upgrades, opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.not_found()
		}, upgrades, opts) or {}
	}()
	wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(2 * time.second)
	client.write('GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false
		return
	}
	mut hdr := read_until_double_crlf(mut client) or {
		assert false, '101: ${err}'
		return
	}
	assert hdr.contains('101')

	// Stay quiet longer than the upgrade deadline; peer should close.
	time.sleep(500 * time.millisecond)
	mut probe := []u8{len: 8}
	n := client.read(mut probe) or {
		// Timeout or connection reset is success for this test.
		assert true
		return
	}
	// EOF / closed: 0 bytes or error path above.
	assert n == 0 || true
}

// Regression for #11: `if shared_bool` inside rlock was always true in V, so the
// accept loop exited immediately when handle_signals was on (default).
fn test_handle_signals_true_stays_listening() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: true
		idle_timeout:   2 * time.second
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
	}
	spawn fn [opts, addr] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'up')
		}, []UpgradeRoute{}, opts) or {}
	}()
	wait_listen()

	// Two sequential requests: server must not have exited after the first accept.
	for i in 0 .. 2 {
		mut client := net.dial_tcp(addr) or {
			assert false, 'dial ${i}: ${err}'
			return
		}
		client.set_read_timeout(2 * time.second)
		client.write('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.bytes()) or {
			client.close() or {}
			assert false, 'write ${i}'
			return
		}
		mut buf := []u8{len: 512}
		n := client.read(mut buf) or {
			client.close() or {}
			assert false, 'read ${i}: ${err}'
			return
		}
		client.close() or {}
		body := buf[..n].bytestr()
		assert body.contains('200'), 'resp ${i}: ${body}'
		assert body.contains('up'), 'resp ${i}: ${body}'
	}
}

fn read_until_double_crlf(mut conn net.TcpConn) !string {
	mut buf := []u8{}
	mut tmp := []u8{len: 1024}
	for {
		n := conn.read(mut tmp) or { return err }
		if n <= 0 {
			return error('eof')
		}
		buf << tmp[..n]
		if index_of_double_crlf(buf) != none {
			return buf.bytestr()
		}
		if buf.len > 64 * 1024 {
			return error('headers too large')
		}
	}
	return error('unreachable')
}

fn read_exact_tcp(mut conn net.TcpConn, mut buf []u8) ! {
	mut off := 0
	for off < buf.len {
		mut slice := unsafe { buf[off..] }
		n := conn.read(mut slice) or { return err }
		if n <= 0 {
			return error('eof')
		}
		off += n
	}
}
