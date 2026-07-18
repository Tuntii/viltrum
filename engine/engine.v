module engine

// TCP accept + HTTP/1.1 message framing (multi-read, body, keep-alive).

import net
import time
import viltrum.http

pub type Handler = fn (req http.Request) http.Response

pub struct ServerOptions {
pub:
	read_chunk_size  int           = 8 * 1024
	max_header_bytes int           = 64 * 1024
	max_body_bytes   int           = 1 * 1024 * 1024
	read_timeout     time.Duration = 30 * time.second
	write_timeout    time.Duration = 30 * time.second
	// require Host on HTTP/1.1 (RFC 7230)
	require_host bool = true
}

pub fn listen_and_serve(addr string, handler Handler) ! {
	listen_and_serve_opt(addr, handler, ServerOptions{})!
}

pub fn listen_and_serve_opt(addr string, handler Handler, opts ServerOptions) ! {
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

fn handle_conn(mut conn net.TcpConn, handler Handler, opts ServerOptions) {
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(opts.read_timeout)
	conn.set_write_timeout(opts.write_timeout)

	mut leftover := []u8{}
	for {
		raw := read_message(mut conn, mut leftover, opts) or {
			// framing errors that warrant an HTTP response + close
			msg := err.msg()
			if msg == 'payload too large' || msg == 'headers too large' || msg == 'message too large' {
				mut resp := http.Response.text(413, msg)
				resp.set_connection_close()
				write_all(mut conn, resp.to_bytes()) or {}
			} else if msg !in ['eof', 'eof during headers', 'eof during body'] {
				mut resp := http.Response.bad_request(msg)
				resp.set_connection_close()
				write_all(mut conn, resp.to_bytes()) or {}
			}
			return
		}

		req := http.parse_request(raw) or {
			mut resp := http.Response.bad_request(err.msg())
			resp.set_connection_close()
			write_all(mut conn, resp.to_bytes()) or {}
			return
		}

		if opts.require_host && req.version.starts_with('HTTP/1.1') {
			if req.headers.get_or('host', '') == '' {
				mut resp := http.Response.bad_request('missing host header')
				resp.set_connection_close()
				write_all(mut conn, resp.to_bytes()) or {}
				return
			}
		}

		if req.body.len > opts.max_body_bytes {
			mut resp := http.Response.text(413, 'payload too large')
			resp.set_connection_close()
			write_all(mut conn, resp.to_bytes()) or {}
			return
		}

		mut resp := handler(req)
		close_after := http.should_close(req, resp)
		if close_after {
			resp.headers.set('Connection', 'close')
		} else if resp.headers.get_or('connection', '') == '' {
			resp.headers.set('Connection', 'keep-alive')
		}

		write_all(mut conn, resp.to_bytes()) or { return }
		if close_after {
			return
		}
	}
}

fn write_all(mut conn net.TcpConn, data []u8) ! {
	mut off := 0
	for off < data.len {
		n := conn.write(data[off..]) or { return err }
		if n <= 0 {
			return error('short write')
		}
		off += n
	}
}

fn read_message(mut conn net.TcpConn, mut leftover []u8, opts ServerOptions) ![]u8 {
	mut buf := leftover.clone()
	leftover = []u8{}

	mut tmp := []u8{len: opts.read_chunk_size}
	for {
		if hdr_end := index_of_double_crlf(buf) {
			body_start := hdr_end + 4
			cl := content_length_from_headers(buf[..hdr_end]) or {
				return finish_message(mut leftover, buf, body_start, 0)
			}
			if cl < 0 {
				return error('negative content-length')
			}
			if cl > opts.max_body_bytes {
				return error('payload too large')
			}
			total := body_start + cl
			for buf.len < total {
				n := conn.read(mut tmp) or { return err }
				if n <= 0 {
					return error('eof during body')
				}
				buf << tmp[..n]
				if buf.len > opts.max_header_bytes + opts.max_body_bytes {
					return error('message too large')
				}
			}
			return finish_message(mut leftover, buf, body_start, cl)
		}

		if buf.len > opts.max_header_bytes {
			return error('headers too large')
		}
		n := conn.read(mut tmp) or { return err }
		if n <= 0 {
			if buf.len == 0 {
				return error('eof')
			}
			return error('eof during headers')
		}
		buf << tmp[..n]
	}
	return error('unreachable')
}

fn finish_message(mut leftover []u8, buf []u8, body_start int, cl int) []u8 {
	total := body_start + cl
	msg := buf[..total].clone()
	if buf.len > total {
		leftover = buf[total..].clone()
	}
	return msg
}

fn index_of_double_crlf(buf []u8) ?int {
	if buf.len < 4 {
		return none
	}
	limit := buf.len - 3
	for i in 0 .. limit {
		if buf[i] == `\r` && buf[i + 1] == `\n` && buf[i + 2] == `\r` && buf[i + 3] == `\n` {
			return i
		}
	}
	return none
}

fn content_length_from_headers(header_bytes []u8) ?int {
	text := header_bytes.bytestr()
	lines := text.split('\r\n')
	for i in 1 .. lines.len {
		line := lines[i]
		lower := line.to_lower()
		if lower.starts_with('content-length:') {
			val := line[line.index(':') or { 0 } + 1..].trim_space()
			return val.int()
		}
	}
	return none
}
