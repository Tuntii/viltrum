module http2

fn test_frame_header_round_trip_all_types() {
	for typ in [frame_data, frame_headers, frame_priority, frame_rst_stream, frame_settings,
		frame_push_promise, frame_ping, frame_goaway, frame_window_update, frame_continuation] {
		mut out := []u8{}
		write_frame_header(mut out, 123456, typ, flag_end_headers, 0x12345678)
		assert out.len == frame_header_len
		header := unsafe { read_frame_header(&out[0]) }
		assert header.length == 123456
		assert header.typ == typ
		assert header.flags == flag_end_headers
		assert header.stream == 0x12345678
	}
}

fn test_frame_header_length_boundaries() {
	for length in [0, max_frame_size] {
		mut out := []u8{}
		write_frame_header(mut out, length, frame_data, 0, 0)
		header := unsafe { read_frame_header(&out[0]) }
		assert header.length == length
	}
}

fn test_frame_header_masks_reserved_stream_bit() {
	bytes := [u8(0), 0, 0, frame_data, flag_ack, 0xff, 0xff, 0xff, 0xff]
	header := read_frame_header(&bytes[0])
	assert header.stream == 0x7fffffff
	assert header.flags == flag_ack
}

fn test_get_u32_reads_big_endian_patterns() {
	first := [u8(0x01), 0x23, 0x45, 0x67]
	second := [u8(0xff), 0x80, 0x00, 0x01]
	assert unsafe { get_u32(&first[0]) } == 0x01234567
	assert unsafe { get_u32(&second[0]) } == 0xff800001
}
