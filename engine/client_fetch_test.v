module engine

import net
import time
import viltrum.http

fn client_free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	a := l.addr() or {
		l.close() or {}
		panic(err)
	}
	s := a.str()
	l.close() or {}
	return s
}

fn test_client_get_and_post() {
	addr := client_free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
	}
	handler := fn (req http.Request) http.Response {
		if req.method == 'POST' {
			return http.Response.text(201, 'got:${req.text()}')
		}
		return http.Response.text(200, 'hi:${req.path}')
	}
	spawn fn [addr, opts, handler] () {
		listen_and_serve_full(addr, handler, [], opts) or {}
	}()
	time.sleep(80 * time.millisecond)

	r1 := http.get(addr, '/ping') or {
		assert false, 'get: ${err}'
		return
	}
	assert r1.status == 200
	assert r1.body.bytestr() == 'hi:/ping'

	r2 := http.post(addr, '/echo', 'abc', 'text/plain') or {
		assert false, 'post: ${err}'
		return
	}
	assert r2.status == 201
	assert r2.body.bytestr() == 'got:abc'
}

fn test_conn_stats_requests_two_keepalive() {
	addr := client_free_addr()
	mut stats := new_conn_stats()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
		stats:          stats
	}
	spawn fn [addr, opts] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, req.path)
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
	c.write('GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	c.write('GET /b HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.bytes()) or {
		assert false, err.msg()
		return
	}
	mut buf := []u8{len: 1024}
	_ := c.read(mut buf) or { 0 }
	start := time.now()
	for {
		snap := stats.snapshot()
		if snap.requests >= 2 {
			assert snap.accepted == 1
			assert snap.requests == 2
			return
		}
		if time.since(start) > 1 * time.second {
			assert false, 'requests=${stats.snapshot().requests} accepted=${stats.snapshot().accepted}'
			return
		}
		time.sleep(5 * time.millisecond)
	}
}
