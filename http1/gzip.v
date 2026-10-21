module http1

const gzip_min_bytes = 256 // below this the gzip framing costs more than it saves

// accepts_gzip reads an Accept-Encoding value: an explicit gzip entry wins over *;
// either counts only with a q-value above zero.
pub fn accepts_gzip(v string) bool {
	mut star := false
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
		mut q_zero := false
		for i < v.len && v[i] != `,` {
			if v[i] == `;` {
				i++
				for i < v.len && (v[i] == ` ` || v[i] == `\t`) {
					i++
				}
				if i + 1 < v.len && lower(v[i]) == `q` && v[i + 1] == `=` {
					i += 2
					qs := i
					for i < v.len && v[i] != `,` && v[i] != `;` && v[i] != ` ` {
						i++
					}
					q_zero = is_q_zero(v, qs, i)
				}
				continue
			}
			i++
		}
		if ce - cs == 4 && lower(v[cs]) == `g` && lower(v[cs + 1]) == `z` && lower(v[cs + 2]) == `i`
			&& lower(v[cs + 3]) == `p` {
			return !q_zero
		}
		if ce - cs == 1 && v[cs] == `*` {
			star = !q_zero
		}
	}
	return star
}

// is_q_zero matches "0", "0.", "0.0", "0.00" and "0.000".
fn is_q_zero(v string, s int, e int) bool {
	if e <= s || v[s] != `0` {
		return false
	}
	for k in s + 1 .. e {
		if k == s + 1 {
			if v[k] != `.` {
				return false
			}
		} else if v[k] != `0` {
			return false
		}
	}
	return true
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
// that accept gzip, and sets Vary on every compressible response. Register it
// before the handlers whose bodies it should compress.
pub fn gzip_middleware(mut c Ctx) {
	c.capture = true
	c.next()
	c.capture = false
	if !c.responded {
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
	if !isnil(c.deflater) && accepts_gzip(c.header('accept-encoding') or { '' }) {
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
