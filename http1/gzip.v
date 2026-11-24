module http1

const gzip_min_bytes = 256 // below this the gzip framing costs more than it saves

// accepts_gzip reads an Accept-Encoding value: an explicit gzip entry wins over *;
// either counts only with a q-value above zero.
pub fn accepts_gzip(v string) bool {
	return accepts_coding(v, 'gzip')
}

// accepts_coding is accepts_gzip for any content coding (lowercase): its explicit
// entry wins over *, and either counts only with a q-value above zero.
pub fn accepts_coding(v string, coding string) bool {
	return coding_q(v, coding) > 0
}

// coding_q is the weight, in thousandths, that the Accept-Encoding value v gives
// coding (lowercase): its explicit entry, else *, else 0. A q-value that does not
// parse counts as 1.
fn coding_q(v string, coding string) int {
	mut star := 0
	mut i := 0
	for i < v.len {
		for i < v.len && (v[i] == ` ` || v[i] == `\t` || v[i] == `,`) {
			i++
		}
		cs := i
		for i < v.len && v[i] != `,` && v[i] != `;` && v[i] != ` ` && v[i] != `\t` {
			i++
		}
		ce := i
		mut q := 1000
		for i < v.len && v[i] != `,` {
			if v[i] == `;` {
				i++
				for i < v.len && (v[i] == ` ` || v[i] == `\t`) {
					i++
				}
				if i + 1 < v.len && lower(v[i]) == `q` && v[i + 1] == `=` {
					i += 2
					qs := i
					for i < v.len && v[i] != `,` && v[i] != `;` && v[i] != ` ` && v[i] != `\t` {
						i++
					}
					q = parse_q(v, qs, i)
				}
				continue
			}
			i++
		}
		if ce - cs == coding.len && coding_is(v, cs, coding) {
			return q
		}
		if ce - cs == 1 && v[cs] == `*` {
			star = q
		}
	}
	return star
}

// coding_is is whether v[s..s + coding.len] is coding, ignoring case.
fn coding_is(v string, s int, coding string) bool {
	for k in 0 .. coding.len {
		if lower(v[s + k]) != coding[k] {
			return false
		}
	}
	return true
}

// parse_q reads the q-value v[s..e] in thousandths: "0", "0.", "0.8", "0.125", "1",
// "1.000". Anything that is not a "0" form, malformed ones included, counts as 1000,
// so only a q-value of zero turns a coding off.
fn parse_q(v string, s int, e int) int {
	if e <= s || v[s] != `0` || (e > s + 1 && v[s + 1] != `.`) {
		return 1000
	}
	mut q := 0
	mut scale := 100
	for k in s + 2 .. e {
		if v[k] < `0` || v[k] > `9` || scale == 0 {
			return 1000
		}
		q += int(v[k] - `0`) * scale
		scale /= 10
	}
	return q
}

// compressible is true for text, JSON, JavaScript, XML and SVG content types.
pub fn compressible(content_type string) bool {
	return has_prefix_ci(content_type, 'text/') || contains_ci(content_type, 'json')
		|| contains_ci(content_type, 'javascript') || contains_ci(content_type, 'xml')
		|| contains_ci(content_type, 'svg')
}

fn contains_ci(s string, lower_lit string) bool {
	if lower_lit.len > s.len {
		return false
	}
	for i in 0 .. s.len - lower_lit.len + 1 {
		mut ok := true
		for k in 0 .. lower_lit.len {
			if lower(s[i + k]) != lower_lit[k] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// gzip_middleware compresses text and JSON bodies of 256 bytes or more for clients
// that accept gzip, and sets Vary on every response it could have compressed: a
// smaller body is the same for every client. Register it before the handlers whose
// bodies it should compress.
pub fn gzip_middleware(mut c Ctx) {
	compress_with(mut c, false)
}

// compress_middleware is gzip_middleware with Brotli too: br for clients that accept
// it, unless they give gzip a higher q-value, and gzip for the rest.
pub fn compress_middleware(mut c Ctx) {
	compress_with(mut c, true)
}

fn compress_with(mut c Ctx, br bool) {
	c.capture = true
	c.next()
	c.capture = false
	// nothing to send, or already sent (a file answer)
	if !c.responded || c.wrote {
		return
	}
	body := c.captured_body()
	eligible := body.len >= gzip_min_bytes && body_allowed(c.status) && compressible(c.cap_type)
		&& !c.has_header('content-encoding')
	if !eligible {
		c.send_captured(body, '')
		return
	}
	c.set_header('Vary', 'Accept-Encoding')
	if isnil(c.deflater) {
		c.send_captured(body, '')
		return
	}
	ae := c.header('accept-encoding') or { '' }
	qgz := coding_q(ae, 'gzip')
	if br {
		qbr := coding_q(ae, 'br')
		if qbr > 0 && qbr >= qgz {
			packed := c.deflater.brotli(body) or {
				c.send_captured(body, '')
				return
			}
			if packed.len < body.len {
				c.send_captured(packed, 'br')
				return
			}
		}
	}
	if qgz > 0 {
		packed := c.deflater.gzip(body) or {
			c.send_captured(body, '')
			return
		}
		if packed.len < body.len {
			c.send_captured(packed, 'gzip')
			return
		}
	}
	c.send_captured(body, '')
}
