module ws

// RFC 6455 frame encode/decode. Server writes unmasked; client frames must be masked.

pub enum Opcode as u8 {
	continuation = 0x0
	text         = 0x1
	binary       = 0x2
	close        = 0x8
	ping         = 0x9
	pong         = 0xA
}

pub fn (o Opcode) is_control() bool {
	return u8(o) & 0x8 != 0
}

pub struct Frame {
pub:
	fin     bool
	opcode  Opcode
	masked  bool
	payload []u8
}

// encode_server builds an unmasked frame (server → client). Single allocation.
pub fn encode_server(fin bool, opcode Opcode, payload []u8) []u8 {
	mut out := []u8{}
	encode_server_into(mut out, fin, opcode, payload)
	return out
}

// encode_server_into writes an unmasked frame into `out`, reusing capacity when possible.
// After return, `out` length is exactly the encoded frame size (for write_all).
pub fn encode_server_into(mut out []u8, fin bool, opcode Opcode, payload []u8) {
	plen := payload.len
	mut header_len := 2
	if plen >= 126 && plen <= 65535 {
		header_len = 4
	} else if plen > 65535 {
		header_len = 10
	}
	need := header_len + plen
	if out.cap < need {
		out = []u8{len: need}
	} else {
		unsafe {
			out.len = need
		}
	}
	mut b0 := u8(opcode) & 0x0f
	if fin {
		b0 |= 0x80
	}
	out[0] = b0
	if plen < 126 {
		out[1] = u8(plen) // MASK bit 0
		if plen > 0 {
			for i in 0 .. plen {
				out[2 + i] = payload[i]
			}
		}
	} else if plen <= 65535 {
		out[1] = 126
		out[2] = u8(plen >> 8)
		out[3] = u8(plen)
		for i in 0 .. plen {
			out[4 + i] = payload[i]
		}
	} else {
		out[1] = 127
		// 64-bit length, high 32 always 0 for practical sizes
		out[2] = 0
		out[3] = 0
		out[4] = 0
		out[5] = 0
		out[6] = u8(u64(plen) >> 24)
		out[7] = u8(u64(plen) >> 16)
		out[8] = u8(u64(plen) >> 8)
		out[9] = u8(plen)
		for i in 0 .. plen {
			out[10 + i] = payload[i]
		}
	}
}

// encode_client builds a masked frame (tests / rare client role).
pub fn encode_client(fin bool, opcode Opcode, payload []u8, mask [4]u8) []u8 {
	plen := payload.len
	mut header_len := 2 + 4
	if plen >= 126 && plen <= 65535 {
		header_len = 4 + 4
	} else if plen > 65535 {
		header_len = 10 + 4
	}
	mut out := []u8{len: header_len + plen}
	mut b0 := u8(opcode) & 0x0f
	if fin {
		b0 |= 0x80
	}
	out[0] = b0
	mut off := 2
	if plen < 126 {
		out[1] = u8(plen) | 0x80
	} else if plen <= 65535 {
		out[1] = 126 | 0x80
		out[2] = u8(plen >> 8)
		out[3] = u8(plen)
		off = 4
	} else {
		out[1] = 127 | 0x80
		out[2] = 0
		out[3] = 0
		out[4] = 0
		out[5] = 0
		out[6] = u8(u64(plen) >> 24)
		out[7] = u8(u64(plen) >> 16)
		out[8] = u8(u64(plen) >> 8)
		out[9] = u8(plen)
		off = 10
	}
	out[off] = mask[0]
	out[off + 1] = mask[1]
	out[off + 2] = mask[2]
	out[off + 3] = mask[3]
	off += 4
	for i in 0 .. plen {
		out[off + i] = payload[i] ^ mask[i & 3]
	}
	return out
}

// parse_frame_header reads the 2-byte base header + extended length + mask key.
// Returns (payload_len, header_total_bytes_after_first_2, masked, fin, opcode, mask_key).
// `hdr` must be at least 2 bytes; caller feeds more as needed via the returned need count.
pub fn peek_header(hdr []u8) !(bool, Opcode, bool, u64, int, [4]u8) {
	if hdr.len < 2 {
		return error('short header')
	}
	fin := hdr[0] & 0x80 != 0
	rsv := hdr[0] & 0x70
	if rsv != 0 {
		return error('rsv bits set')
	}
	op := unsafe { Opcode(hdr[0] & 0x0f) }
	masked := hdr[1] & 0x80 != 0
	mut plen := u64(hdr[1] & 0x7f)
	mut need := 0 // bytes after the first 2
	if plen == 126 {
		need = 2
	} else if plen == 127 {
		need = 8
	}
	if masked {
		need += 4
	}
	if hdr.len < 2 + need {
		return error('need more header')
	}
	mut off := 2
	if plen == 126 {
		plen = u64(hdr[2]) << 8 | u64(hdr[3])
		off = 4
	} else if plen == 127 {
		// reject non-zero high 32 bits (messages > 4GB)
		if hdr[2] != 0 || hdr[3] != 0 || hdr[4] != 0 || hdr[5] != 0 {
			return error('payload too large')
		}
		plen = u64(hdr[6]) << 24 | u64(hdr[7]) << 16 | u64(hdr[8]) << 8 | u64(hdr[9])
		off = 10
	}
	mut mask := [4]u8{}
	if masked {
		mask[0] = hdr[off]
		mask[1] = hdr[off + 1]
		mask[2] = hdr[off + 2]
		mask[3] = hdr[off + 3]
	}
	return fin, op, masked, plen, need, mask
}

// unmask_in_place XORs payload with the 4-byte mask key.
pub fn unmask_in_place(mut payload []u8, mask [4]u8) {
	for i in 0 .. payload.len {
		payload[i] = payload[i] ^ mask[i & 3]
	}
}

// close_payload builds the optional close body (code + reason).
pub fn close_payload(code u16, reason string) []u8 {
	if code == 0 && reason.len == 0 {
		return []u8{}
	}
	rb := reason.bytes()
	mut out := []u8{len: 2 + rb.len}
	out[0] = u8(code >> 8)
	out[1] = u8(code)
	for i in 0 .. rb.len {
		out[2 + i] = rb[i]
	}
	return out
}

// parse_close_payload extracts status code and reason from a close frame body.
pub fn parse_close_payload(payload []u8) (u16, string) {
	if payload.len == 0 {
		return 1005, '' // no status received (local convention)
	}
	if payload.len == 1 {
		return 1002, '' // invalid
	}
	code := u16(payload[0]) << 8 | u16(payload[1])
	if payload.len == 2 {
		return code, ''
	}
	return code, payload[2..].bytestr()
}
