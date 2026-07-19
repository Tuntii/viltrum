module engine

// TCP accept + HTTP/1.1 framing + upgrade/hijack (v0.4).

import net
import os
import sync
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
	idle_timeout     time.Duration = 60 * time.second
	// read_header_timeout applies while assembling headers; 0 means use read_timeout.
	read_header_timeout time.Duration
	// max_conns bounds concurrent connections (0 = unlimited). Excess accepts get 503 then close.
	max_conns int
	// send_date adds Date (HTTP-date, UTC) when the handler did not set Date. Default off.
	send_date bool
	// server_header if non-empty sets Server when the handler did not. Default empty (omit).
	server_header string
	require_host bool = true
	// handle_signals installs SIGINT/SIGTERM shutdown (disable in embedded/bench/tests).
	handle_signals bool = true
}

// ActiveConns tracks live connections for max_conns (mutex, not shared int — portable on V).
struct ActiveConns {
mut:
	mu sync.Mutex
	n  int
}

fn (mut a ActiveConns) try_acquire(max int) bool {
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if max > 0 && a.n >= max {
		return false
	}
	a.n++
	return true
}

fn (mut a ActiveConns) release() {
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if a.n > 0 {
		a.n--
	}
}

pub fn listen_and_serve(addr string, handler Handler) ! {
	listen_and_serve_full(addr, handler, []UpgradeRoute{}, ServerOptions{})!
}

pub fn listen_and_serve_opt(addr string, handler Handler, opts ServerOptions) ! {
	listen_and_serve_full(addr, handler, []UpgradeRoute{}, opts)!
}

// listen_and_serve_full is the full server entry: HTTP handler + optional upgrade routes.
pub fn listen_and_serve_full(addr string, handler Handler, upgrades []UpgradeRoute, opts ServerOptions) ! {
	mut listener := net.listen_tcp(.ip, addr)!
	shared stopping := false
	mut active := &ActiveConns{}

	if opts.handle_signals {
		os.signal_opt(.int, fn [shared stopping, mut listener] () {
			lock stopping {
				stopping = true
			}
			eprintln('[viltrum] shutting down (SIGINT)')
			listener.close() or {}
		}) or {}
		os.signal_opt(.term, fn [shared stopping, mut listener] () {
			lock stopping {
				stopping = true
			}
			eprintln('[viltrum] shutting down (SIGTERM)')
			listener.close() or {}
		}) or {}
	}

	defer {
		listener.close() or {}
	}
	eprintln('[viltrum] listening on http://${addr}')
	for {
		if opts.handle_signals {
			rlock stopping {
				if stopping {
					break
				}
			}
		}
		mut conn := listener.accept() or {
			if opts.handle_signals {
				mut stop := false
				rlock stopping {
					stop = stopping
				}
				if stop {
					break
				}
			}
			msg := err.msg().to_lower()
			if msg.contains('closed') || msg.contains('invalid') || msg.contains('bad file') {
				break
			}
			eprintln('[viltrum] accept error: ${err}')
			continue
		}

		track := opts.max_conns > 0
		if track {
			if !active.try_acquire(opts.max_conns) {
				// Bound reached: short 503 then close (no keep-alive, no handler).
				mut busy := http.Response.text(503, 'service unavailable')
				busy.set_connection_close()
				apply_response_defaults(mut busy, opts)
				write_tcp(mut conn, busy.to_bytes()) or {}
				conn.close() or {}
				continue
			}
		}

		spawn handle_conn(mut conn, handler, upgrades, opts, active, track)
	}
	eprintln('[viltrum] stopped')
}

fn handle_conn(mut conn net.TcpConn, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, active &ActiveConns, track bool) {
	mut hijacked := false
	defer {
		if track {
			unsafe {
				mut a := &ActiveConns(active)
				a.release()
			}
		}
		if !hijacked {
			conn.close() or {}
		}
	}

	conn.set_read_timeout(opts.read_timeout)
	conn.set_write_timeout(opts.write_timeout)

	mut leftover := []u8{}
	mut first := true
	for {
		if !first {
			conn.set_read_timeout(opts.idle_timeout)
		}
		first = false

		raw := read_message(mut conn, mut leftover, opts) or {
			msg := err.msg()
			kind := classify_read_error(msg)
			if kind != 'eof' {
				eprintln('[viltrum] conn read: ${kind}: ${msg}')
			}
			if kind == 'limit' {
				mut resp := http.Response.text(413, msg)
				resp.set_connection_close()
				apply_response_defaults(mut resp, opts)
				write_tcp(mut conn, resp.to_bytes()) or {}
			} else if kind == 'protocol' {
				mut resp := http.Response.bad_request(msg)
				resp.set_connection_close()
				apply_response_defaults(mut resp, opts)
				write_tcp(mut conn, resp.to_bytes()) or {}
			}
			return
		}

		conn.set_read_timeout(opts.read_timeout)

		req := http.parse_request(raw) or {
			eprintln('[viltrum] conn parse: protocol: ${err.msg()}')
			mut resp := http.Response.bad_request(err.msg())
			resp.set_connection_close()
			apply_response_defaults(mut resp, opts)
			write_tcp(mut conn, resp.to_bytes()) or {}
			return
		}

		if opts.require_host && req.version.starts_with('HTTP/1.1') {
			if req.headers.get_or('host', '') == '' {
				mut resp := http.Response.bad_request('missing host header')
				resp.set_connection_close()
				apply_response_defaults(mut resp, opts)
				write_tcp(mut conn, resp.to_bytes()) or {}
				return
			}
		}

		if req.body.len > opts.max_body_bytes {
			mut resp := http.Response.text(413, 'payload too large')
			resp.set_connection_close()
			apply_response_defaults(mut resp, opts)
			write_tcp(mut conn, resp.to_bytes()) or {}
			return
		}

		// --- upgrade / hijack: leave HTTP loop, transfer Conn ownership ---
		if hit := match_upgrade(upgrades, req) {
			mut rq := req
			rq.params = hit.params.clone()
			// leftover holds bytes past this HTTP message (pipelined / early data).
			// Move them into Conn pushback; HTTP loop never resumes.
			buffered := leftover.clone()
			leftover = []u8{}
			hijacked = true
			mut c := Conn.wrap(mut conn, buffered)
			c.set_read_timeout(opts.read_timeout)
			c.set_write_timeout(opts.write_timeout)
			hit.handler(mut c, rq)
			if !c.is_closed() {
				c.close() or {}
			}
			return
		}

		mut resp := handler(req)
		close_after := http.should_close(req, resp)
		if close_after {
			resp.headers.set('Connection', 'close')
		} else if resp.headers.get_or('connection', '') == '' {
			resp.headers.set('Connection', 'keep-alive')
		}
		apply_response_defaults(mut resp, opts)

		write_tcp(mut conn, resp.to_bytes_for_method(req.method)) or { return }
		if close_after {
			return
		}
	}
}

// apply_response_defaults sets optional Date / Server when enabled and not already present.
// Does not run for upgrade handlers (they write their own bytes on Conn).
fn apply_response_defaults(mut resp http.Response, opts ServerOptions) {
	if opts.send_date && resp.headers.get_or('date', '') == '' {
		resp.headers.set('Date', http.http_date(time.utc()))
	}
	if opts.server_header.len > 0 && resp.headers.get_or('server', '') == '' {
		resp.headers.set('Server', opts.server_header)
	}
}

fn classify_read_error(msg string) string {
	return match true {
		msg in ['eof', 'eof during headers', 'eof during body'] { 'eof' }
		msg.contains('timeout') || msg.contains('timed out') { 'timeout' }
		msg in ['payload too large', 'headers too large', 'message too large'] { 'limit' }
		else { 'protocol' }
	}
}

fn write_tcp(mut conn net.TcpConn, data []u8) ! {
	mut off := 0
	for off < data.len {
		n := conn.write(data[off..]) or { return err }
		if n <= 0 {
			return error('short write')
		}
		off += n
	}
}

fn header_timeout(opts ServerOptions) time.Duration {
	if opts.read_header_timeout > 0 {
		return opts.read_header_timeout
	}
	return opts.read_timeout
}

fn read_message(mut conn net.TcpConn, mut leftover []u8, opts ServerOptions) ![]u8 {
	mut buf := leftover.clone()
	leftover = []u8{}

	mut tmp := []u8{len: opts.read_chunk_size}
	mut sent_100 := false
	mut saw_bytes := buf.len > 0
	if saw_bytes {
		// Already have data (from prior leftover); apply header timeout for the rest.
		conn.set_read_timeout(header_timeout(opts))
	}

	for {
		if hdr_end := index_of_double_crlf(buf) {
			body_start := hdr_end + 4
			hdr := unsafe { buf[..hdr_end] }

			// TE + CL together is a protocol error (RFC 9112); reject before TE-not-supported.
			te := transfer_encoding_present(hdr)
			cl_opt := content_length_from_headers(hdr)
			if te && cl_opt != none {
				return error('transfer-encoding and content-length conflict')
			}
			if te {
				return error('transfer-encoding not supported')
			}

			cl := cl_opt or { return finish_message(mut leftover, buf, body_start, 0) }
			if cl < 0 {
				return error('negative content-length')
			}
			if cl > opts.max_body_bytes {
				return error('payload too large')
			}

			// Body phase uses read_timeout (distinct from header timeout).
			conn.set_read_timeout(opts.read_timeout)

			if !sent_100 && cl > 0 && expects_100_continue(hdr) {
				if buf.len < body_start + cl {
					write_tcp(mut conn, 'HTTP/1.1 100 Continue\r\n\r\n'.bytes()) or {
						return error('write 100-continue failed')
					}
					sent_100 = true
				}
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
		if !saw_bytes {
			// First byte after idle wait: switch to header assembly timeout.
			saw_bytes = true
			conn.set_read_timeout(header_timeout(opts))
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

fn transfer_encoding_present(header_bytes []u8) bool {
	text := header_bytes.bytestr()
	lines := text.split('\r\n')
	for i in 1 .. lines.len {
		lower := lines[i].to_lower()
		if lower.starts_with('transfer-encoding:') {
			val := lower['transfer-encoding:'.len..].trim_space()
			return val.len > 0
		}
	}
	return false
}

fn expects_100_continue(header_bytes []u8) bool {
	text := header_bytes.bytestr()
	lines := text.split('\r\n')
	for i in 1 .. lines.len {
		lower := lines[i].to_lower()
		if lower.starts_with('expect:') {
			val := lower['expect:'.len..].trim_space()
			return val == '100-continue'
		}
	}
	return false
}
