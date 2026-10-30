module http1

import time

fn test_status_line_and_headers() {
	mut out := []u8{}
	write_status_line(mut out, 200)
	write_header(mut out, 'Content-Type', 'text/plain')
	assert out.bytestr() == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
	unsafe {
		out.len = 0
	}
	write_status_line(mut out, 599)
	assert out.bytestr() == 'HTTP/1.1 599 Unknown\r\n'
	assert reason(404) == 'Not Found' && reason(413) == 'Content Too Large'
	assert !body_allowed(204) && !body_allowed(304) && !body_allowed(100) && body_allowed(200)
}

fn test_date_matches_time_formatting() {
	mut d := DateCache{}
	mut ts := i64(0)
	for ts < 4102444800 {
		d.format(ts)
		want := time.unix(ts).custom_format('ddd, DD MMM YYYY HH:mm:ss') + ' GMT'
		assert d.text[..].bytestr() == want, ts.str()
		ts += 839_999
	}
}

fn test_date_write_allocates_nothing() {
	mut d := DateCache{}
	mut out := []u8{cap: 4096}
	d.write(mut out)
	assert out.bytestr().starts_with('Date: ') && out.len == 37
	before := allocated_bytes()
	for _ in 0 .. 10000 {
		unsafe {
			out.len = 0
		}
		d.write(mut out)
		write_status_line(mut out, 200)
		write_header(mut out, 'Server', 'viltrum')
	}
	assert allocated_bytes() - before == 0
}

// write above stays in one second; format runs once per second per worker.
fn test_date_format_allocates_nothing() {
	mut d := DateCache{}
	before := allocated_bytes()
	for ts := i64(0); ts < 4102444800; ts += 839_999 {
		d.format(ts)
	}
	assert allocated_bytes() - before == 0
}
