module http1

const chunked_req = 'POST /c HTTP/1.1\r\nHost: x\r\ntransfer-encoding: Chunked\r\n\r\n' +
	'4;name=val\r\nWiki\r\n5 \r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: 1\r\n\r\n'

fn frame_all(raw string) !int {
	mut f := Frame{}
	return frame(raw.bytes(), mut f, Limits{})
}

fn status_of(raw string) int {
	frame_all(raw) or { return err.code() }
	return 0
}

fn test_content_length_framing() {
	get := 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'
	assert frame_all(get + 'GET')! == get.len
	post := 'POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello'
	assert frame_all(post + 'GET / HTTP/1.1')! == post.len
	assert frame_all('POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel')! == -1
	assert frame_all('GET / HTTP/1.1\r\nHost: x\r\n')! == -1
	lower_cl := 'POST / HTTP/1.1\r\ncontent-length:  2 \r\n\r\n20'
	assert frame_all(lower_cl)! == lower_cl.len
}

fn test_framing_errors_carry_status() {
	assert status_of('POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello') == 400
	assert status_of('POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n') == 400
	assert status_of('POST / HTTP/1.1\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n') == 400
	for cl in ['abc', '+5', '-1', '5, 5', '5 5', ''] {
		assert status_of('POST / HTTP/1.1\r\nContent-Length: ${cl}\r\n\r\nhello') == 400, cl
	}
	// lengths past the limit, however long, are too large rather than malformed
	for cl in ['2000000', '4294967301', '99999999999999999999'] {
		assert status_of('POST / HTTP/1.1\r\nContent-Length: ${cl}\r\n\r\n') == 413, cl
	}
	lead := 'POST / HTTP/1.1\r\nContent-Length: 00000000002\r\n\r\n20'
	assert frame_all(lead)! == lead.len
	big := 'GET / HTTP/1.1\r\nX: ' + 'a'.repeat(70000)
	assert status_of(big) == 431
	assert status_of(big + '\r\n\r\n') == 431
}

fn test_chunk_errors_carry_status() {
	head := 'POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n'
	for body in ['0x5\r\nhello\r\n0\r\n\r\n', '-5\r\nhello\r\n0\r\n\r\n',
		'000000005\r\nhello\r\n0\r\n\r\n', '5\r\nhelloX0\r\n\r\n', '5\nhello\r\n0\r\n\r\n',
		'5 x\r\nhello\r\n0\r\n\r\n', '0\r\nBad Trailer\r\n\r\n'] {
		assert status_of(head + body) == 400, body
	}
	assert status_of(head + 'ffffff\r\n') == 413
	assert status_of(head + '0\r\nX: ' + 'a'.repeat(9000) + '\r\n\r\n') == 431
	assert status_of(head + '5;' + 'e'.repeat(5000)) == 400
	assert status_of(head + '5;' + 'e'.repeat(5000) + '\r\nhello\r\n0\r\n\r\n') == 400
}

// The body and trailer caps add up over chunks and trailer lines that are each under
// them, also when the message arrives one byte at a time.
fn test_chunk_caps_add_up_across_reads() {
	head := 'POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n'
	small := Limits{
		max_body_bytes: 10
	}
	for msg, want in {
		head + '8\r\n12345678\r\n8\r\n12345678\r\n0\r\n\r\n':        413
		head + '0\r\n' + 'X-T: aaaaaaaaaa\r\n'.repeat(600) + '\r\n': 431
	} {
		raw := msg.bytes()
		mut whole := Frame{}
		assert frame(raw, mut whole, small) or { err.code() } == want
		mut f := Frame{}
		mut got := 0
		for n in 1 .. raw.len + 1 {
			frame(view(raw, 0, n), mut f, small) or {
				got = err.code()
				break
			}
		}
		assert got == want
	}
}

fn test_expect_continue_is_flagged_once_head_is_complete() {
	mut f := Frame{}
	raw := 'POST / HTTP/1.1\r\nExpect: 100-Continue\r\nContent-Length: 2\r\n\r\n'.bytes()
	assert frame(raw, mut f, Limits{})! == -1
	assert f.expect_continue
}

// Feeding one byte at a time must end exactly at the message end, never earlier.
fn test_frame_resumes_byte_by_byte() {
	post := 'POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello'
	for msg in [chunked_req, post] {
		raw := (msg + 'GET /next HTTP/1.1\r\n\r\n').bytes()
		mut f := Frame{}
		mut done := false
		for n in 1 .. raw.len + 1 {
			got := frame(view(raw, 0, n), mut f, Limits{})!
			if got >= 0 {
				assert n == msg.len
				assert got == msg.len
				done = true
				break
			}
		}
		assert done
	}
}

fn test_decode_chunked() {
	raw := chunked_req.bytes()
	mut f := Frame{}
	assert frame(raw, mut f, Limits{})! == raw.len
	assert f.chunked
	mut out := []u8{}
	decode_chunked(raw, f.head_end, mut out)
	assert out.bytestr() == 'Wikipedia in\r\n\r\nchunks.'
}

fn test_header_value_skips_request_line_and_trims() {
	head := 'GET /content-length: HTTP/1.1\r\nHost:  a.b \r\nX-Y:\r\n\r\n'.bytes()
	h := header_value(head, 'host')
	assert str_view(head, h.start, h.len) == 'a.b'
	assert !header_value(head, 'content-length').found()
	e := header_value(head, 'x-y')
	assert e.found() && e.len == 0
}

fn test_framing_allocates_nothing() {
	get := 'GET /plaintext HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\n'.bytes()
	post := chunked_req.bytes()
	mut out := []u8{cap: 256}
	before := allocated_bytes()
	for _ in 0 .. 10000 {
		mut f := Frame{}
		_ = frame(get, mut f, Limits{}) or { -2 }
		mut g := Frame{}
		_ = frame(post, mut g, Limits{}) or { -2 }
		unsafe {
			out.len = 0
		}
		decode_chunked(post, g.head_end, mut out)
	}
	assert allocated_bytes() - before == 0
}
