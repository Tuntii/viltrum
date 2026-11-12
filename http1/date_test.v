module http1

fn test_format_imf_known_epochs() {
	cases := {
		i64(0):       'Thu, 01 Jan 1970 00:00:00 GMT'
		951782400:    'Tue, 29 Feb 2000 00:00:00 GMT'
		2147483648:   'Tue, 19 Jan 2038 03:14:08 GMT'
		253402300799: 'Fri, 31 Dec 9999 23:59:59 GMT'
	}
	mut buf := [29]u8{}
	for secs, want in cases {
		format_imf(secs, &buf[0])
		got := unsafe { tos(&buf[0], 29) }
		assert got == want, got
	}
}

fn test_parse_imf_round_trip() {
	mut buf := [29]u8{}
	for secs in [i64(0), 784111777, 951782400, 1700000000, 2147483648, 4102444799, 253402300799] {
		format_imf(secs, &buf[0])
		s := unsafe { tos(&buf[0], 29) }
		assert parse_imf(s) or { -1 } == secs, s
	}
	assert parse_imf('Sun, 06 Nov 1994 08:49:37 GMT') or { -1 } == 784111777
}

fn test_parse_imf_rejects_malformed_input() {
	for bad in ['Sunday, 06-Nov-94 08:49:37 GMT', 'Sun Nov  6 08:49:37 1994',
		'Sun, 06 Nov 1994 08:49:37 UTC', 'Sun, 06 Xyz 1994 08:49:37 GMT',
		'Sun, 6a Nov 1994 08:49:37 GMT', 'Sun, 06 Nov 1994 25:49:37 GMT',
		'Sun, 06 Nov 1994 08:60:37 GMT', 'Sun, 06 Nov 1994 08:49:61 GMT',
		'Sun, 00 Nov 1994 08:49:37 GMT', 'Sun, 32 Nov 1994 08:49:37 GMT', ''] {
		assert parse_imf(bad) == none, bad
	}
}
