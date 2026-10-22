module http1

fn test_imf_dates_round_trip() {
	mut buf := [29]u8{}
	for secs in [i64(0), 784111777, 951782400, 1700000000, 4102444799, 253402300799] {
		format_imf(secs, &buf[0])
		s := unsafe { tos(&buf[0], 29) }
		assert parse_imf(s) or { -1 } == secs, s
	}
	assert parse_imf('Sun, 06 Nov 1994 08:49:37 GMT') or { -1 } == 784111777
	for bad in ['Sunday, 06-Nov-94 08:49:37 GMT', 'Sun Nov  6 08:49:37 1994',
		'Sun, 06 Nov 1994 08:49:37 UTC', 'Sun, 06 Xyz 1994 08:49:37 GMT',
		'Sun, 6a Nov 1994 08:49:37 GMT', 'Sun, 06 Nov 1994 25:49:37 GMT', ''] {
		assert parse_imf(bad) == none, bad
	}
}

fn test_parse_range() {
	cases := {
		'bytes=0-0':                      [i64(0), 0]
		'bytes=0-99':                     [i64(0), 99]
		'bytes=10-':                      [i64(10), 99]
		'bytes=90-500':                   [i64(90), 99]
		'bytes=-10':                      [i64(90), 99]
		'bytes=-1000':                    [i64(0), 99]
		'Bytes=1-2':                      [i64(1), 2]
		' bytes=1-2 ':                    [i64(1), 2]
		'bytes=100-':                     [range_unsatisfiable, range_unsatisfiable]
		'bytes=-0':                       [range_unsatisfiable, range_ignore]
		'bytes=5-4':                      [range_ignore, range_ignore]
		'bytes=1-2,4-5':                  [range_ignore, range_ignore]
		'bytes=-':                        [range_ignore, range_ignore]
		'bytes=a-b':                      [range_ignore, range_ignore]
		'bytes 1-2':                      [range_ignore, range_ignore]
		'lines=1-2':                      [range_ignore, range_ignore]
		'bytes=1 -2':                     [range_ignore, range_ignore]
		'bytes=99999999999999999999999-': [range_unsatisfiable, range_unsatisfiable]
	}
	for v, want in cases {
		s, e := parse_range(v, 100)
		if want[0] == range_unsatisfiable {
			assert s == range_unsatisfiable, v
		} else if want[0] == range_ignore {
			assert s == range_ignore, v
		} else {
			assert s == want[0] && e == want[1], v
		}
	}
}

fn test_etag_lists() {
	e := '"5f-1a"'
	for list in ['"5f-1a"', 'W/"5f-1a"', '"x", "5f-1a"', '"x",W/"5f-1a"', '*', ' "5f-1a" '] {
		assert etag_listed(list, e), list
	}
	for list in ['"5f-1b"', '5f-1a', '', '"5f-1a', 'W/', '"5f-1a"x'] {
		assert !etag_listed(list, e), list
	}
}

fn test_content_types() {
	assert content_type_for('a/b/index.HTML') == 'text/html; charset=utf-8'
	assert content_type_for('x.min.js') == 'text/javascript; charset=utf-8'
	assert content_type_for('font.woff2') == 'font/woff2'
	assert content_type_for('dir.d/README') == 'application/octet-stream'
	assert content_type_for('noext') == 'application/octet-stream'
	assert content_type_for('trailing.') == 'application/octet-stream'
}

fn rel_path(rel string, dotfiles bool) ?string {
	mut c := Ctx.new()
	append_str(mut c.pbuf, 'root/')
	if !c.append_rel(rel, dotfiles) {
		return none
	}
	return c.pbuf.bytestr()
}

fn test_relative_paths() {
	assert rel_path('a/b.txt', false) or { '' } == 'root/a/b.txt'
	assert rel_path('', false) or { '' } == 'root/'
	assert rel_path('a//b/', false) or { '' } == 'root/a/b'
	assert rel_path('a%20b', false) or { '' } == 'root/a b'
	assert rel_path('a%2Fb', false) or { '' } == 'root/a/b'
	assert rel_path('.well-known/x', true) or { '' } == 'root/.well-known/x'
	for bad in ['..', 'a/../b', '%2e%2e', 'a/%2E%2E/b', '.', 'a/./b', '..%2fx', 'a%00b', 'a%5cb',
		'a\\b', '%', '%2', '%g0', '.env', 'a/.git/config'] {
		assert rel_path(bad, false) == none, bad
	}
	assert rel_path('..', true) == none && rel_path('.', true) == none
}
