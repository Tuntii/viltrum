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
