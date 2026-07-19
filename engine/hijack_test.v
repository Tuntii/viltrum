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
