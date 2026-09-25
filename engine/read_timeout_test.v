module engine

import net
import os
import time
import viltrum.http

fn read_free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	a := l.addr() or {
		l.close() or {}
		panic(err)
	}
	s := a.str()
	l.close() or {}
	return s
}

fn test_cleartext_read_path_is_recv_after_rcvtimeo() {
	$if !linux {
		return
	}
	src := os.read_file(os.dir(@FILE) + '/conn_read_linux.c.v') or {
		assert false, 'read conn_read_linux.c.v: ${err}'
		return
	}
	assert src.contains('SO_RCVTIMEO')
	assert src.contains('C.recv(')
	assert !src.contains('select(')
	assert !src.contains('pselect')
	assert !src.contains('poll(')
	assert !src.contains('wait_for_read')
	assert !src.contains('c.tcp.read(')
	// Deadline is installed only when the duration changes, then recv.
	assert src.contains('c.rcv_installed && c.rcv_dur == d')
}

fn test_cleartext_keepalive_two_under_read_timeout() {
	addr := read_free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
	}
	spawn fn [addr, opts] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'ka:${req.path}')
		}, [], opts) or {}
	}()
	time.sleep(80 * time.millisecond)

	mut c := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		c.close() or {}
	}
	c.set_read_timeout(2 * time.second)
	c.set_write_timeout(2 * time.second)
	c.write('GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	mut buf := []u8{len: 2048}
	n1 := c.read(mut buf) or {
		assert false, 'read1: ${err}'
		return
	}
	body1 := buf[..n1].bytestr()
	assert body1.contains('200')
	assert body1.contains('ka:/one')

	c.write('GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	n2 := c.read(mut buf) or {
		assert false, 'read2: ${err}'
		return
	}
	body2 := buf[..n2].bytestr()
	assert body2.contains('200')
	assert body2.contains('ka:/two')
}

fn test_stalled_peer_hits_read_timeout() {
	addr := read_free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   200 * time.millisecond
		write_timeout:  2 * time.second
		idle_timeout:   200 * time.millisecond
	}
	spawn fn [addr, opts] () {
		listen_and_serve_full(addr, fn (_ http.Request) http.Response {
			return http.Response.text(200, 'nope')
		}, [], opts) or {}
	}()
	time.sleep(80 * time.millisecond)

	mut c := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		c.close() or {}
	}
	c.set_read_timeout(2 * time.second)
	// Peer sends nothing. The server read deadline must close the socket.
	start := time.now()
	mut buf := []u8{len: 256}
	c.read(mut buf) or {
		// Server closed the socket, or the client read timed out. Either way, measure elapsed.
	}
	elapsed := time.since(start)
	assert elapsed < 1500 * time.millisecond, 'stalled peer was not cut off (${elapsed})'
	assert elapsed >= 100 * time.millisecond
}
