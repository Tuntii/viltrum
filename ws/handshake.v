module ws

// RFC 6455 opening handshake helpers (server side).

import crypto.sha1
import encoding.base64
import viltrum.http

// RFC 6455 §1.3 magic GUID concatenated with Sec-WebSocket-Key.
const ws_guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

// accept_key returns Sec-WebSocket-Accept for a client Sec-WebSocket-Key.
// Golden: key `dGhlIHNhbXBsZSBub25jZQ==` → `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`
pub fn accept_key(client_key string) string {
	sum := sha1.sum((client_key + ws_guid).bytes())
	return base64.encode(sum)
}

// validate_upgrade checks method + required headers. Returns the client key on success.
// Error codes: 405 method, 400 bad request headers, 426 wrong WS version.
pub fn validate_upgrade(req http.Request) !string {
	if req.method.to_upper() != 'GET' {
		return error_with_code('WebSocket upgrade requires GET', 405)
	}
	upgrade := req.headers.get_or('upgrade', '').to_lower()
	if !header_token_has(upgrade, 'websocket') {
		return error_with_code('missing or invalid Upgrade: websocket', 400)
	}
	connection := req.headers.get_or('connection', '').to_lower()
	if !header_token_has(connection, 'upgrade') {
		return error_with_code('missing or invalid Connection: Upgrade', 400)
	}
	version := req.headers.get_or('sec-websocket-version', '')
	if version != '13' {
		return error_with_code('Sec-WebSocket-Version must be 13', 426)
	}
	key := req.headers.get_or('sec-websocket-key', '').trim_space()
	if key.len < 8 {
		return error_with_code('missing or invalid Sec-WebSocket-Key', 400)
	}
	return key
}

// handshake_status extracts HTTP status from a validate_upgrade error (default 400).
pub fn handshake_status(err IError) int {
	code := err.code()
	if code >= 400 && code < 600 {
		return code
	}
	return 400
}

// switching_ws builds the 101 response with Sec-WebSocket-Accept (and optional protocol).
pub fn switching_ws(client_key string, subprotocol string) http.Response {
	mut r := http.Response.switching_protocols('websocket')
	r.headers.set('Sec-WebSocket-Accept', accept_key(client_key))
	if subprotocol.len > 0 {
		r.headers.set('Sec-WebSocket-Protocol', subprotocol)
	}
	return r
}

// pick_subprotocol returns `wanted` if the client offered it in Sec-WebSocket-Protocol, else ''.
pub fn pick_subprotocol(req http.Request, wanted string) string {
	if wanted.len == 0 {
		return ''
	}
	offered := req.headers.get_or('sec-websocket-protocol', '')
	if offered.len == 0 {
		return ''
	}
	for part in offered.split(',') {
		if part.trim_space() == wanted {
			return wanted
		}
	}
	return ''
}

// header_token_has is true if a comma-separated header list contains token (case already lowercased).
fn header_token_has(header_value string, token string) bool {
	if header_value.len == 0 {
		return false
	}
	if header_value == token {
		return true
	}
	for part in header_value.split(',') {
		if part.trim_space() == token {
			return true
		}
	}
	return false
}
