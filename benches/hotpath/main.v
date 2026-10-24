module main

// The request hot path without sockets: one worker, 16 pipelined requests per
// batch, 1M requests per run, best of 7. Frame, parse, route, handler, response.
import time
import viltrum.http1
import viltrum.router
import viltrum.engine

struct Msg {
	message string
}

fn ok(mut c http1.Ctx) {
	c.text(200, 'ok')
}

fn js(mut c http1.Ctx) {
	c.json(200, Msg{
		message: 'Hello, World!'
	})
}

fn usr(mut c http1.Ctx) {
	c.text(200, c.param('id') or { '' })
}

fn main() {
	mut r := &router.Router{}
	r.add(.get, '/', [http1.Handler(ok)])!
	r.add(.get, '/json', [http1.Handler(js)])!
	r.add(.get, '/users/:id', [http1.Handler(usr)])!
	r.add(.post, '/users/:id', [http1.Handler(usr)])!
	mut w := engine.new_worker(r, engine.Options{}, 0)
	for p in ['/', '/json', '/users/42'] {
		req := 'GET ${p} HTTP/1.1\r\nHost: bench\r\nAccept: */*\r\n\r\n'.repeat(16).bytes()
		mut c := engine.new_conn()
		mut best := u64(max_u64)
		for _ in 0 .. 7 {
			t0 := time.sys_mono_now()
			for _ in 0 .. 62500 {
				unsafe {
					c.rbuf.len = 0
					c.wbuf.len = 0
				}
				c.rbuf << req
				w.process(mut c)
			}
			dt := time.sys_mono_now() - t0
			if dt < best {
				best = dt
			}
		}
		println('${p} ${f64(best) / 1_000_000.0:.1f} ns/req')
	}
}
