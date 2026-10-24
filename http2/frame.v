module http2

// HTTP/2 framing (RFC 9113 4 and 6): the frame header, the frame types, flags,
// settings and error codes the engine uses.

// preface is what a client sends first on every HTTP/2 connection (RFC 9113 3.4).
pub const preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'

pub const frame_header_len = 9
pub const default_frame_size = 16384 // SETTINGS_MAX_FRAME_SIZE's initial value
pub const max_frame_size = 16777215 // the most it may be set to
pub const default_window = 65535 // SETTINGS_INITIAL_WINDOW_SIZE's initial value, and the connection's
pub const max_window = 0x7fffffff

// frame types
pub const frame_data = u8(0x0)
pub const frame_headers = u8(0x1)
pub const frame_priority = u8(0x2)
pub const frame_rst_stream = u8(0x3)
pub const frame_settings = u8(0x4)
pub const frame_push_promise = u8(0x5)
pub const frame_ping = u8(0x6)
pub const frame_goaway = u8(0x7)
pub const frame_window_update = u8(0x8)
pub const frame_continuation = u8(0x9)

// flags
pub const flag_end_stream = u8(0x1)
pub const flag_ack = u8(0x1)
pub const flag_end_headers = u8(0x4)
pub const flag_padded = u8(0x8)
pub const flag_priority = u8(0x20)

// settings
pub const settings_header_table_size = 0x1
pub const settings_enable_push = 0x2
pub const settings_max_concurrent_streams = 0x3
pub const settings_initial_window_size = 0x4
pub const settings_max_frame_size = 0x5
pub const settings_max_header_list_size = 0x6

// error codes
pub const err_no_error = u32(0x0)
pub const err_protocol = u32(0x1)
pub const err_internal = u32(0x2)
pub const err_flow_control = u32(0x3)
pub const err_stream_closed = u32(0x5)
pub const err_frame_size = u32(0x6)
pub const err_refused_stream = u32(0x7)
pub const err_cancel = u32(0x8)
pub const err_compression = u32(0x9)
pub const err_enhance_your_calm = u32(0xb)

// FrameHeader is the 9 bytes before every frame's payload.
pub struct FrameHeader {
pub:
	length int
	typ    u8
	flags  u8
	stream u32 // the reserved bit cleared
}

// read_frame_header reads the frame header at p (the caller checked there are 9 bytes).
pub fn read_frame_header(p &u8) FrameHeader {
	unsafe {
		return FrameHeader{
			length: int(u32(p[0]) << 16 | u32(p[1]) << 8 | u32(p[2]))
			typ:    p[3]
			flags:  p[4]
			stream: get_u32(p + 5) & 0x7fffffff
		}
	}
}

// write_frame_header appends a frame header.
pub fn write_frame_header(mut out []u8, length int, typ u8, flags u8, stream u32) {
	out << u8(length >> 16)
	out << u8(length >> 8)
	out << u8(length)
	out << typ
	out << flags
	put_u32(mut out, stream)
}

// get_u32 reads a big-endian 32-bit integer.
@[unsafe]
pub fn get_u32(p &u8) u32 {
	unsafe {
		return u32(p[0]) << 24 | u32(p[1]) << 16 | u32(p[2]) << 8 | u32(p[3])
	}
}

// put_u32 appends a big-endian 32-bit integer.
pub fn put_u32(mut out []u8, v u32) {
	out << u8(v >> 24)
	out << u8(v >> 16)
	out << u8(v >> 8)
	out << u8(v)
}
