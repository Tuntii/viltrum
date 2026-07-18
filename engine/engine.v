module engine

// TCP accept loop + per-connection read. No veb. HTTP parse is in viltrum.http.

import net
import time

pub type RawHandler = fn (raw_req []u8) []u8

pub struct ServerOptions {
pub:
	read_buffer_size int           = 16 * 1024
	read_timeout     time.Duration = 30 * time.second
	write_timeout    time.Duration = 30 * time.second
}

pub fn listen_and_serve(addr string, handler RawHandler) ! {
	listen_and_serve_opt(addr, handler, ServerOptions{})!
}

pub fn listen_and_serve_opt(addr string, handler RawHandler, opts ServerOptions) ! {
	mut listener := net.listen_tcp(.ip, addr)!
	defer {
		listener.close() or {}
	}
	eprintln('[viltrum] listening on http://${addr}')
	for {
		mut conn := listener.accept() or {
			eprintln('[viltrum] accept error: ${err}')
			continue
		}
		spawn handle_conn(mut conn, handler, opts)
	}
}

fn handle_conn(mut conn net.TcpConn, handler RawHandler, opts ServerOptions) {
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(opts.read_timeout)
	conn.set_write_timeout(opts.write_timeout)

	mut buf := []u8{len: opts.read_buffer_size}
	n := conn.read(mut buf) or { return }
	if n <= 0 {
		return
	}
	raw := buf[..n].clone()
	resp := handler(raw)
	if resp.len == 0 {
		return
	}
	conn.write(resp) or {}
}
