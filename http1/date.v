module http1

fn C.time(t voidptr) i64

const day_names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const month_names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov',
	'Dec']

// DateCache holds the IMF-fixdate for the current second. A worker owns one, so
// the header is formatted at most once per second per worker.
pub struct DateCache {
mut:
	sec  i64 = -1
	text [29]u8
}

// write appends `Date: <IMF-fixdate>\r\n`.
pub fn (mut d DateCache) write(mut out []u8) {
	append_str(mut out, 'Date: ')
	unsafe { out.push_many(d.text_now(), 29) }
	append_str(mut out, crlf)
}

// text_now is the IMF-fixdate of the current second (29 bytes), formatted again only
// when the second changes.
fn (mut d DateCache) text_now() &u8 {
	now := C.time(unsafe { nil })
	if now != d.sec {
		d.sec = now
		d.format(now)
	}
	return &d.text[0]
}

// format writes "Sun, 06 Nov 1994 08:49:37 GMT" into text.
fn (mut d DateCache) format(secs i64) {
	format_imf(secs, &d.text[0])
}

// format_imf writes the IMF-fixdate of secs (29 bytes) at p.
fn format_imf(secs i64, p &u8) {
	// Civil-from-days arithmetic: time.unix(...).day_of_week() allocates, this does not.
	days := secs / 86400
	rem := int(secs % 86400)
	z := days + 719468
	era := z / 146097
	doe := int(z - era * 146097)
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	day := doy - (153 * mp + 2) / 5 + 1
	month := if mp < 10 { mp + 3 } else { mp - 9 }
	year := int(era) * 400 + yoe + if month <= 2 { 1 } else { 0 }
	dow := int((days + 3) % 7) // 1970-01-01 was a Thursday; Monday = 0
	unsafe {
		mut q := put_str(p, day_names[dow])
		q = put_str(q, ', ')
		q = put2(q, day)
		q[0] = ` `
		q = put_str(q + 1, month_names[month - 1])
		q[0] = ` `
		q = put2(q + 1, year / 100)
		q = put2(q, year % 100)
		q[0] = ` `
		q = put2(q + 1, rem / 3600)
		q[0] = `:`
		q = put2(q + 1, rem / 60 % 60)
		q[0] = `:`
		q = put2(q + 1, rem % 60)
		put_str(q, ' GMT')
	}
}

@[inline; unsafe]
fn put2(p &u8, n int) &u8 {
	unsafe {
		p[0] = u8(`0` + n / 10)
		p[1] = u8(`0` + n % 10)
		return p + 2
	}
}

// parse_imf reads an IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT") as seconds since
// the epoch. The two obsolete formats RFC 9110 also allows are refused (none): a
// condition that cannot be read is ignored, which only costs a full response.
fn parse_imf(s string) ?i64 {
	if s.len != 29 || s[3] != `,` || s[4] != ` ` || s[7] != ` ` || s[11] != ` ` || s[16] != ` `
		|| s[19] != `:` || s[22] != `:` || s[25] != ` ` || s[26] != `G` || s[27] != `M`
		|| s[28] != `T` {
		return none
	}
	day := digits2(s, 5)?
	mut month := -1
	for k in 0 .. 12 {
		m := month_names[k]
		if s[8] == m[0] && s[9] == m[1] && s[10] == m[2] {
			month = k + 1
			break
		}
	}
	if month < 0 {
		return none
	}
	year := digits2(s, 12)? * 100 + digits2(s, 14)?
	hh := digits2(s, 17)?
	mm := digits2(s, 20)?
	ss := digits2(s, 23)?
	if day < 1 || day > 31 || hh > 23 || mm > 59 || ss > 60 {
		return none
	}
	// days-from-civil, the inverse of format_imf
	y := if month <= 2 { year - 1 } else { year }
	era := (if y >= 0 { y } else { y - 399 }) / 400
	yoe := y - era * 400
	mp := if month > 2 { month - 3 } else { month + 9 }
	doy := (153 * mp + 2) / 5 + day - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := i64(era) * 146097 + doe - 719468
	return days * 86400 + hh * 3600 + mm * 60 + ss
}

fn digits2(s string, i int) ?int {
	a := s[i]
	b := s[i + 1]
	if a < `0` || a > `9` || b < `0` || b > `9` {
		return none
	}
	return int(a - `0`) * 10 + int(b - `0`)
}
