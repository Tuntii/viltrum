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
	mut i := d.put_str(0, day_names[dow])
	i = d.put_str(i, ', ')
	i = d.put2(i, day)
	d.text[i] = ` `
	i = d.put_str(i + 1, month_names[month - 1])
	d.text[i] = ` `
	i = d.put2(i + 1, year / 100)
	i = d.put2(i, year % 100)
	d.text[i] = ` `
	i = d.put2(i + 1, rem / 3600)
	d.text[i] = `:`
	i = d.put2(i + 1, rem / 60 % 60)
	d.text[i] = `:`
	i = d.put2(i + 1, rem % 60)
	d.put_str(i, ' GMT')
}

fn (mut d DateCache) put_str(i int, s string) int {
	for k in 0 .. s.len {
		d.text[i + k] = s[k]
	}
	return i + s.len
}

fn (mut d DateCache) put2(i int, n int) int {
	d.text[i] = u8(`0` + n / 10)
	d.text[i + 1] = u8(`0` + n % 10)
	return i + 2
}
