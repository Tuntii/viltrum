module ws

// Socket is a server-side WebSocket on an engine.Conn after a successful 101.

import viltrum.engine
import viltrum.http

// Handler owns the Socket for the rest of the connection life.
pub type Handler = fn (mut s Socket)

// OriginCheck returns true if the Origin header (or empty) is allowed.
// Nil / unused means no origin filtering (default).
pub type OriginCheck = fn (origin string) bool

pub struct Options {
pub:
	// max_message_bytes caps a single data message payload (default 1 MiB).
	max_message_bytes int = 1 << 20
	// max_frame_bytes caps one frame including control (default same as message).
	max_frame_bytes int = 1 << 20
	// auto_pong replies to ping frames with a matching pong (default true).
	auto_pong bool = true
	// subprotocol is echoed in Sec-WebSocket-Protocol if the client offered it.
	subprotocol string
	// check_origin: if set, Origin must pass; missing Origin fails when set.
	// Use carefully for browser clients; leave unset for tools/non-browser.
	check_origin OriginCheck = unsafe { nil }
}

pub struct Message {
pub:
	opcode Opcode
	data   []u8
}

pub fn (m &Message) text() string {
	return m.data.bytestr()
}

pub fn (m &Message) is_text() bool {
	return m.opcode == .text
}

pub fn (m &Message) is_binary() bool {
	return m.opcode == .binary
}

pub struct Socket {
mut:
	conn   engine.Conn
	opts   Options
	closed bool
	// peer_close_code set when a close frame is received
	peer_close_code   u16
	peer_close_reason string
}

// wrap takes ownership of the upgraded Conn.
pub fn Socket.wrap(mut conn engine.Conn, opts Options) Socket {
	max_msg := if opts.max_message_bytes <= 0 { 1 << 20 } else { opts.max_message_bytes }
	max_fr := if opts.max_frame_bytes <= 0 { max_msg } else { opts.max_frame_bytes }
	return Socket{
		conn: conn
		opts: Options{
			max_message_bytes: max_msg
			max_frame_bytes:   max_fr
			auto_pong:         opts.auto_pong
			subprotocol:       opts.subprotocol
			check_origin:      opts.check_origin
		}
		closed: false
	}
}

pub fn (s &Socket) is_closed() bool {
	return s.closed
}

pub fn (s &Socket) peer_close() (u16, string) {
	return s.peer_close_code, s.peer_close_reason
}

// write_text sends a single complete text message.
pub fn (mut s Socket) write_text(text string) ! {
	s.write_message(.text, text.bytes())!
}

// write_binary sends a single complete binary message.
pub fn (mut s Socket) write_binary(data []u8) ! {
	s.write_message(.binary, data)!
}

// write_message sends one unfragmented data frame.
pub fn (mut s Socket) write_message(opcode Opcode, data []u8) ! {
	if s.closed {
		return error('ws closed')
	}
	if opcode != .text && opcode != .binary {
		return error('write_message requires text or binary opcode')
	}
	if data.len > s.opts.max_message_bytes {
		return error('message exceeds max_message_bytes')
	}
	frame := encode_server(true, opcode, data)
	s.conn.write_all(frame)!
}

// ping sends a ping control frame (payload ≤ 125 bytes).
pub fn (mut s Socket) ping(payload []u8) ! {
	if payload.len > 125 {
		return error('ping payload too large')
	}
	s.write_control(.ping, payload)!
}

// pong sends a pong control frame.
pub fn (mut s Socket) pong(payload []u8) ! {
	if payload.len > 125 {
		return error('pong payload too large')
	}
	s.write_control(.pong, payload)!
}

fn (mut s Socket) write_control(opcode Opcode, payload []u8) ! {
	if s.closed {
		return error('ws closed')
	}
	frame := encode_server(true, opcode, payload)
	s.conn.write_all(frame)!
}

// close sends a close frame (code + reason) and marks the socket closed.
// Code 0 with empty reason sends an empty close body.
pub fn (mut s Socket) close(code u16, reason string) ! {
	if s.closed {
		return
	}
	payload := close_payload(code, reason)
	if payload.len > 125 {
		return error('close reason too long')
	}
	frame := encode_server(true, .close, payload)
	s.conn.write_all(frame) or {
		s.closed = true
		s.conn.close() or {}
		return err
	}
	s.closed = true
	s.conn.close() or {}
}

// close_quiet best-effort close with normal closure.
pub fn (mut s Socket) close_quiet() {
	s.close(1000, '') or {
		s.closed = true
		s.conn.close() or {}
	}
}

// read_message blocks until a full data message, peer close, or error.
// Ping frames are answered automatically when auto_pong is on; pongs are ignored.
// Fragmented data frames are rejected with close 1002.
pub fn (mut s Socket) read_message() !Message {
	for {
		if s.closed {
			return error('ws closed')
		}
		frame := s.read_frame()!
		if frame.opcode.is_control() {
			s.handle_control(frame)!
			continue
		}
		// data opcodes
		match frame.opcode {
			.text, .binary {
				if !frame.fin {
					s.close(1002, 'fragmented messages not supported') or {}
					return error('fragmented message')
				}
				if frame.payload.len > s.opts.max_message_bytes {
					s.close(1009, 'message too big') or {}
					return error('message too big')
				}
				return Message{
					opcode: frame.opcode
					data:   frame.payload
				}
			}
			.continuation {
				s.close(1002, 'unexpected continuation') or {}
				return error('unexpected continuation')
			}
			else {
				s.close(1002, 'invalid opcode') or {}
				return error('invalid opcode')
			}
		}
	}
	return error('ws closed')
}

fn (mut s Socket) handle_control(frame Frame) ! {
	if !frame.fin {
		s.close(1002, 'fragmented control') or {}
		return error('fragmented control')
	}
	if frame.payload.len > 125 {
		s.close(1002, 'control payload too large') or {}
		return error('control payload too large')
	}
	match frame.opcode {
		.close {
			code, reason := parse_close_payload(frame.payload)
			s.peer_close_code = code
			s.peer_close_reason = reason
			// Echo close if we have not closed yet (RFC 6455)
			if !s.closed {
				// use peer code if valid range, else 1000
				echo_code := if code >= 1000 && code < 5000 { code } else { u16(1000) }
				payload := close_payload(echo_code, '')
				frame_out := encode_server(true, .close, payload)
				s.conn.write_all(frame_out) or {}
				s.closed = true
				s.conn.close() or {}
			}
			return error('ws closed by peer')
		}
		.ping {
			if s.opts.auto_pong {
				s.write_control(.pong, frame.payload)!
			}
		}
		.pong {
			// ignore
		}
		else {
			s.close(1002, 'unknown control') or {}
			return error('unknown control')
		}
	}
}

// read_frame reads one complete frame from the Conn (pushback-aware).
pub fn (mut s Socket) read_frame() !Frame {
	if s.closed {
		return error('ws closed')
	}
	// Read base 2 bytes, then extended header as needed.
	mut hdr := []u8{len: 14} // max 2+8+4
	s.conn.read_exact(mut hdr[..2])!

	// Determine how many more header bytes we need.
	masked_bit := hdr[1] & 0x80 != 0
	mut len7 := hdr[1] & 0x7f
	mut extra := 0
	if len7 == 126 {
		extra = 2
	} else if len7 == 127 {
		extra = 8
	}
	if masked_bit {
		extra += 4
	}
	if extra > 0 {
		s.conn.read_exact(mut hdr[2..2 + extra])!
	}

	fin, opcode, masked, plen_u64, _, mask := peek_header(hdr[..2 + extra]) or { return err }

	// Server requires client frames to be masked.
	if !masked {
		s.close(1002, 'client frames must be masked') or {}
		return error('unmasked client frame')
	}
	if opcode.is_control() {
		if plen_u64 > 125 {
			s.close(1002, 'control frame too large') or {}
			return error('control frame too large')
		}
		if !fin {
			s.close(1002, 'fragmented control') or {}
			return error('fragmented control')
		}
	}
	if plen_u64 > u64(s.opts.max_frame_bytes) {
		s.close(1009, 'frame too big') or {}
		return error('frame too big')
	}
	plen := int(plen_u64)
	mut payload := []u8{len: plen}
	if plen > 0 {
		s.conn.read_exact(mut payload)!
		unmask_in_place(mut payload, mask)
	}
	return Frame{
		fin:     fin
		opcode:  opcode
		masked:  masked
		payload: payload
	}
}

// serve_upgrade runs handshake on an UpgradeFn conn, then handler.
// On handshake failure writes an HTTP error and closes.
pub fn serve_upgrade(mut c engine.Conn, req http.Request, opts Options, handler Handler) {
	// Origin check (optional)
	if opts.check_origin != unsafe { nil } {
		origin := req.headers.get_or('origin', '')
		if !opts.check_origin(origin) {
			write_http_err(mut c, 403, 'origin not allowed')
			return
		}
	}
	key := validate_upgrade(req) or {
		write_http_err(mut c, handshake_status(err), err.msg())
		return
	}
	proto := pick_subprotocol(req, opts.subprotocol)
	resp := switching_ws(key, proto)
	c.write_all(resp.to_bytes()) or {
		c.close() or {}
		return
	}
	mut sock := Socket.wrap(mut c, opts)
	handler(mut sock)
	if !sock.is_closed() {
		sock.close_quiet()
	}
}

// make_upgrade builds an engine.UpgradeFn for app.upgrade / app.ws wiring.
pub fn make_upgrade(opts Options, handler Handler) engine.UpgradeFn {
	return fn [opts, handler] (mut c engine.Conn, req http.Request) {
		serve_upgrade(mut c, req, opts, handler)
	}
}

fn write_http_err(mut c engine.Conn, status int, msg string) {
	resp := http.Response.text(status, msg)
	mut r := resp
	r.set_connection_close()
	c.write_all(r.to_bytes()) or {}
	c.close() or {}
}
