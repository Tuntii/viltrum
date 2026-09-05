module http

// Minimal HTTP/1.1 client. One request per connection (Connection: close).
// Not a general client library: no redirects, cookies, pooling, or HTTP/2.
// Cleartext: fetch. TLS: fetch_tls (mbedtls). Production edge TLS still belongs
// at the reverse proxy.

import net
import net.mbedtls
import time

pub struct ClientOptions {
pub:
	read_timeout  time.Duration = 30 * time.second
	write_timeout time.Duration = 30 * time.second
}

// ClientTls is the optional TLS side of fetch_tls. No mTLS, no SNI matrix.
pub struct ClientTls {
pub:
	// insecure_skip_verify skips server cert checks (self-signed / tests). Default true.
	insecure_skip_verify bool = true
	// ca_file is a PEM CA path when verify is on (insecure_skip_verify false).
	ca_file string
}

// fetch dials addr (host:port), writes req, reads one response, closes.
pub fn fetch(addr string, req Request) !Response {
	return fetch_opt(addr, req, ClientOptions{})
}

pub fn fetch_opt(addr string, req Request, opts ClientOptions) !Response {
	mut conn := net.dial_tcp(addr)!
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(opts.read_timeout)
	conn.set_write_timeout(opts.write_timeout)
	wire := serialize_request(req, addr)
	conn.write(wire)!
	return read_client_response(mut conn)!
}

// get is fetch of GET path on addr.
pub fn get(addr string, path string) !Response {
	mut h := HeaderMap.new()
	h.set_lowered('host', host_from_addr(addr))
	h.set_lowered('connection', 'close')
	req := Request{
		method:  'GET'
		target:  path
		path:    path
		version: 'HTTP/1.1'
		headers: h
	}
	return fetch(addr, req)
}

// post sends a body with the given Content-Type.
pub fn post(addr string, path string, body string, content_type string) !Response {
	mut h := HeaderMap.new()
	h.set_lowered('host', host_from_addr(addr))
	h.set_lowered('connection', 'close')
	ct := if content_type.len > 0 { content_type } else { 'text/plain; charset=utf-8' }
	h.set_lowered('content-type', ct)
	h.set_lowered('content-length', '${body.len}')
	req := Request{
		method:  'POST'
		target:  path
		path:    path
		version: 'HTTP/1.1'
		headers: h
		body:    body.bytes()
	}
	return fetch(addr, req)
}

// fetch_tls is fetch over mbedtls TLS. One connection, Connection: close.
pub fn fetch_tls(addr string, req Request, tls ClientTls) !Response {
	return fetch_tls_opt(addr, req, ClientOptions{}, tls)
}

pub fn fetch_tls_opt(addr string, req Request, opts ClientOptions, tls ClientTls) !Response {
	host, port := split_host_port(addr)!
	mut ssl := mbedtls.new_ssl_conn(mbedtls.SSLConnectConfig{
		validate: !tls.insecure_skip_verify
		verify:   tls.ca_file
	})!
	ssl.dial(host, port)!
	defer {
		ssl.close() or {}
	}
	ssl.set_read_timeout(opts.read_timeout)
	wire := serialize_request(req, addr)
	ssl.write(wire)!
	return read_client_response_ssl(mut ssl)!
}

pub fn get_tls(addr string, path string, tls ClientTls) !Response {
	mut h := HeaderMap.new()
	h.set_lowered('host', host_from_addr(addr))
	h.set_lowered('connection', 'close')
	req := Request{
		method:  'GET'
		target:  path
		path:    path
		version: 'HTTP/1.1'
		headers: h
	}
	return fetch_tls(addr, req, tls)
}

pub fn post_tls(addr string, path string, body string, content_type string, tls ClientTls) !Response {
	mut h := HeaderMap.new()
	h.set_lowered('host', host_from_addr(addr))
	h.set_lowered('connection', 'close')
	ct := if content_type.len > 0 { content_type } else { 'text/plain; charset=utf-8' }
	h.set_lowered('content-type', ct)
	h.set_lowered('content-length', '${body.len}')
	req := Request{
		method:  'POST'
		target:  path
		path:    path
		version: 'HTTP/1.1'
		headers: h
		body:    body.bytes()
	}
	return fetch_tls(addr, req, tls)
}

fn host_from_addr(addr string) string {
	return host_header_value(addr)
}

// host_header_value builds a Host header from host:port.
// IPv6 is bracketed. :80 / :443 are omitted; other ports stay (no change for 127.0.0.1:ephemeral).
fn host_header_value(addr string) string {
	if addr.starts_with('[') {
		rb := addr.index(']') or { return addr }
		host := addr[..rb + 1]
		if rb + 1 < addr.len && addr[rb + 1] == `:` {
			port := addr[rb + 2..]
			if port == '80' || port == '443' {
				return host
			}
		}
		return addr
	}
	col := addr.last_index(':') or { return addr }
	if addr.count(':') > 1 {
		// Unbracketed IPv6 — Host wants brackets.
		return '[${addr}]'
	}
	port := addr[col + 1..]
	if port == '80' || port == '443' {
		return addr[..col]
	}
	return addr
}

fn split_host_port(addr string) !(string, int) {
	if addr.starts_with('[') {
		rb := addr.index(']') or { return error('client: bad ipv6 address') }
		host := addr[1..rb]
		if rb + 2 > addr.len || addr[rb + 1] != `:` {
			return error('client: missing port')
		}
		return host, addr[rb + 2..].int()
	}
	col := addr.last_index(':') or { return error('client: missing port') }
	if addr.count(':') > 1 {
		return error('client: ipv6 address must be [host]:port')
	}
	p := addr[col + 1..].int()
	if p <= 0 {
		return error('client: bad port')
	}
	return addr[..col], p
}

fn serialize_request(req Request, addr string) []u8 {
	target := if req.target.len > 0 { req.target } else { req.path }
	method := if req.method.len > 0 { req.method } else { 'GET' }
	version := if req.version.len > 0 { req.version } else { 'HTTP/1.1' }
	mut out := '${method} ${target} ${version}\r\n'
	mut saw_host := false
	mut saw_conn := false
	mut saw_cl := false
	for k, v in req.headers.values {
		if k == 'host' {
			saw_host = true
		}
		if k == 'connection' {
			saw_conn = true
		}
		if k == 'content-length' {
			saw_cl = true
		}
		out += '${canonicalize_header_name(k)}: ${v}\r\n'
	}
	if !saw_host {
		out += 'Host: ${host_from_addr(addr)}\r\n'
	}
	if !saw_conn {
		out += 'Connection: close\r\n'
	}
	if req.body.len > 0 && !saw_cl {
		out += 'Content-Length: ${req.body.len}\r\n'
	}
	out += '\r\n'
	mut bytes := out.bytes()
	if req.body.len > 0 {
		bytes << req.body
	}
	return bytes
}

fn read_client_response(mut conn net.TcpConn) !Response {
	return finish_client_read(fn [mut conn] (mut tmp []u8) !int {
		return conn.read(mut tmp)
	})
}

fn read_client_response_ssl(mut ssl mbedtls.SSLConn) !Response {
	return finish_client_read(fn [mut ssl] (mut tmp []u8) !int {
		return ssl.read(mut tmp)
	})
}

fn finish_client_read(read_fn fn (mut []u8) !int) !Response {
	mut buf := []u8{}
	mut tmp := []u8{len: 4096}
	for {
		n := read_fn(mut tmp) or { return err }
		if n <= 0 {
			return error('client: eof before headers')
		}
		buf << tmp[..n]
		if sep := index_of_double_crlf(buf) {
			hdr_end := sep + 4
			hdr := unsafe { buf[..hdr_end] }
			cl := client_content_length(hdr)
			need := hdr_end + cl
			for buf.len < need {
				n2 := read_fn(mut tmp) or { return err }
				if n2 <= 0 {
					return error('client: eof during body')
				}
				buf << tmp[..n2]
			}
			return parse_client_response(buf[..need])
		}
		if buf.len > 256 * 1024 {
			return error('client: headers too large')
		}
	}
	return error('client: unreachable')
}

fn client_content_length(hdr []u8) int {
	text := hdr.bytestr().to_lower()
	key := 'content-length:'
	idx := text.index(key) or { return 0 }
	mut rest := text[idx + key.len..]
	nl := rest.index('\r\n') or { rest.len }
	return rest[..nl].trim_space().int()
}

fn parse_client_response(raw []u8) !Response {
	sep := index_of_double_crlf(raw) or { return error('client: no header separator') }
	head := raw[..sep].bytestr()
	line_end := head.index('\r\n') or { head.len }
	line := head[..line_end]
	parts := line.split(' ')
	if parts.len < 2 {
		return error('client: bad status line')
	}
	status := parts[1].int()
	reason := if parts.len > 2 { parts[2..].join(' ') } else { '' }
	mut headers := HeaderMap.new()
	if line_end + 2 < head.len {
		for raw_line in head[line_end + 2..].split('\r\n') {
			if raw_line.len == 0 {
				continue
			}
			c := raw_line.index(':') or { continue }
			headers.add(raw_line[..c].trim_space(), raw_line[c + 1..].trim_space())
		}
	}
	mut body := []u8{}
	if raw.len > sep + 4 {
		body = raw[sep + 4..].clone()
	}
	return Response{
		status:  status
		reason:  reason
		headers: headers
		body:    body
	}
}
