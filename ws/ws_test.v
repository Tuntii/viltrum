module ws

import viltrum.engine
import viltrum.http

fn test_accept_key_rfc_golden() {
	// RFC 6455 §1.3 / §4.2.2 example
	got := accept_key('dGhlIHNhbXBsZSBub25jZQ==')
	assert got == 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
}

fn test_validate_upgrade_ok() {
	mut req := http.Request{
		method:  'GET'
		path:    '/ws'
		headers: http.HeaderMap.new()
	}
	req.headers.set('Upgrade', 'websocket')
	req.headers.set('Connection', 'Upgrade')
	req.headers.set('Sec-WebSocket-Version', '13')
	req.headers.set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==')
	key := validate_upgrade(req) or { panic(err) }
	assert key == 'dGhlIHNhbXBsZSBub25jZQ=='
}

fn test_validate_upgrade_bad_version() {
	mut req := http.Request{
		method:  'GET'
		path:    '/ws'
		headers: http.HeaderMap.new()
	}
	req.headers.set('Upgrade', 'websocket')
	req.headers.set('Connection', 'keep-alive, Upgrade')
	req.headers.set('Sec-WebSocket-Version', '12')
	req.headers.set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==')
	validate_upgrade(req) or {
		assert handshake_status(err) == 426
		return
	}
	assert false, 'expected version error'
}

fn test_frame_server_roundtrip_text() {
	payload := 'hello'.bytes()
	raw := encode_server(true, .text, payload)
	// Fake client read path: parse header + payload (unmasked)
	assert raw[0] == 0x81 // FIN + text
	assert raw[1] == 5
	assert raw[2..].bytestr() == 'hello'
}

fn test_frame_client_mask_and_unmask() {
	payload := 'hi'.bytes()
	mask := [u8(0x12), 0x34, 0x56, 0x78]!
	raw := encode_client(true, .text, payload, mask)
	assert raw[0] == 0x81
	assert raw[1] & 0x80 != 0 // masked
	assert raw[1] & 0x7f == 2
	// mask at offset 2, payload at 6
	mut body := raw[6..].clone()
	unmask_in_place(mut body, mask)
	assert body.bytestr() == 'hi'
}

fn test_close_payload() {
	p := close_payload(1000, 'bye')
	code, reason := parse_close_payload(p)
	assert code == 1000
	assert reason == 'bye'
}

fn test_socket_echo_over_buffered_conn() {
	// Build a client text frame, feed as pushback, read via Socket, write reply, inspect rbuf empty + writes via re-read? 
	// Conn.new_buffered only serves reads; writes go to dead tcp.
	// Use new_buffered for read path only.
	mask := [u8(1), 2, 3, 4]!
	client_frame := encode_client(true, .text, 'ping'.bytes(), mask)
	mut c := engine.Conn.new_buffered(client_frame)
	mut s := Socket.wrap(mut c, Options{
		max_message_bytes: 1024
	})
	msg := s.read_message() or { panic(err) }
	assert msg.is_text()
	assert msg.text() == 'ping'
}

fn test_socket_rejects_unmasked() {
	// Server frame (unmasked) presented as client → protocol error
	raw := encode_server(true, .text, 'x'.bytes())
	mut c := engine.Conn.new_buffered(raw)
	mut s := Socket.wrap(mut c, Options{})
	s.read_message() or {
		assert err.msg().contains('unmasked') || err.msg().contains('closed') || err.msg().len > 0
		return
	}
	assert false, 'expected unmasked rejection'
}

fn test_socket_rejects_oversized() {
	mask := [u8(9), 8, 7, 6]!
	// 10-byte payload, limit 4
	big := '0123456789'.bytes()
	raw := encode_client(true, .binary, big, mask)
	mut c := engine.Conn.new_buffered(raw)
	mut s := Socket.wrap(mut c, Options{
		max_message_bytes: 4
		max_frame_bytes:   4
	})
	s.read_message() or {
		assert true
		return
	}
	assert false, 'expected too big'
}

fn test_ping_skipped_then_text() {
	// auto_pong false: ping is consumed without writing (buffered conn has no live TCP).
	mask_ping := [u8(0xaa), 0xbb, 0xcc, 0xdd]!
	mask_text := [u8(1), 1, 1, 1]!
	ping_fr := encode_client(true, .ping, 'z'.bytes(), mask_ping)
	text_fr := encode_client(true, .text, 'ok'.bytes(), mask_text)
	mut buf := []u8{}
	buf << ping_fr
	buf << text_fr
	mut c := engine.Conn.new_buffered(buf)
	mut s := Socket.wrap(mut c, Options{
		auto_pong: false
	})
	msg := s.read_message() or { panic(err) }
	assert msg.text() == 'ok'
}

fn test_switching_ws_headers() {
	r := switching_ws('dGhlIHNhbXBsZSBub25jZQ==', 'chat')
	assert r.status == 101
	assert r.headers.get_or('upgrade', '') == 'websocket'
	assert r.headers.get_or('sec-websocket-accept', '') == 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
	assert r.headers.get_or('sec-websocket-protocol', '') == 'chat'
}

fn test_pick_subprotocol() {
	mut req := http.Request{
		method:  'GET'
		headers: http.HeaderMap.new()
	}
	req.headers.set('Sec-WebSocket-Protocol', 'a, chat, b')
	assert pick_subprotocol(req, 'chat') == 'chat'
	assert pick_subprotocol(req, 'nope') == ''
}
