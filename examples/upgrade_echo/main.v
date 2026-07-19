module main

// Upgrade demo: GET /echo takes over the connection after 101, then echoes lines.
//
//   v run examples/upgrade_echo
//   printf 'GET /echo HTTP/1.1\r\nHost: localhost\r\n\r\nhello\n' | nc 127.0.0.1 8083

import viltrum

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: true
	})

	app.get('/', fn (req viltrum.Request) viltrum.Response {
		return viltrum.text(200, 'upgrade demo: GET /echo\n')
	})

	app.upgrade('GET', '/echo', fn (mut c viltrum.Conn, req viltrum.Request) {
		resp := viltrum.switching_protocols('echo')
		c.write_all(resp.to_bytes()) or {
			eprintln('write 101: ${err}')
			return
		}
		// Simple echo loop: read chunks, write them back, until EOF/error.
		mut buf := []u8{len: 4096}
		for {
			n := c.read(mut buf) or { break }
			if n == 0 {
				break
			}
			c.write_all(buf[..n]) or { break }
		}
		c.close() or {}
	})

	println('upgrade_echo on http://127.0.0.1:8083  (GET /echo)')
	app.listen('127.0.0.1:8083') or { panic(err) }
}
