module http1

// Conveniences for handlers: HTML and redirects, cookies, the method as text, the
// body as text, and the Allow header of a 405. None of them runs unless a handler
// calls it, and none allocates: request values are views, and the header values
// they build live in a small buffer inside the Ctx.

pub const ct_html = 'text/html; charset=utf-8'

// name is the method's token as written on the wire ('GET'); 'OTHER' for an
// extension method (Ctx.method_name has its exact spelling).
pub fn (m Method) name() string {
	return match m {
		.get { 'GET' }
		.head { 'HEAD' }
		.post { 'POST' }
		.put { 'PUT' }
		.delete { 'DELETE' }
		.patch { 'PATCH' }
		.options { 'OPTIONS' }
		.connect { 'CONNECT' }
		.trace { 'TRACE' }
		.other { 'OTHER' }
	}
}

// method_name is the request method exactly as the client sent it.
pub fn (c &Ctx) method_name() string {
	if c.head.method_raw.len == 0 {
		return c.head.method.name()
	}
	return str_view(c.buf, c.head.method_raw.start, c.head.method_raw.len)
}

// body_text is the request body as a string view, for decoders that take a string
// (json2.decode[T](c.body_text())). Valid until the handler returns.
pub fn (c &Ctx) body_text() string {
	return str_view(c.body_bytes, 0, c.body_bytes.len)
}

pub fn (mut c Ctx) html(status int, s string) {
	c.respond(status, ct_html, s.str, s.len)
}

// redirect answers status (301, 302, 303, 307 or 308) with a Location header and an
// empty body. 303 sends a browser's form POST on as a GET; 307 and 308 keep the method.
pub fn (mut c Ctx) redirect(status int, location string) {
	c.set_header('Location', location)
	c.respond(status, '', unsafe { nil }, 0)
}

// --- cookies ---

pub enum SameSite {
	lax
	strict
	cross_site // SameSite=None; sent with Secure, which browsers require for it
	unset      // no SameSite attribute
}

// Cookie is a Set-Cookie line. The defaults are the safe ones for a session: the
// whole site (Path=/), not readable from JavaScript (HttpOnly), and not sent on
// cross-site subrequests (SameSite=Lax).
@[params]
pub struct Cookie {
pub:
	name      string @[required]
	value     string
	path      string = '/'
	domain    string
	max_age   int // seconds; 0 leaves it a session cookie
	secure    bool
	http_only bool     = true
	same_site SameSite = .lax
}

// cookie returns the value of the request cookie name, unquoted. Every Cookie header
// is searched; the first match wins.
pub fn (c &Ctx) cookie(name string) ?string {
	for k in 0 .. c.head.nfields {
		f := c.head.fields[k]
		if !eq_ci_span(c.buf, f.name, 'cookie') {
			continue
		}
		mut i := f.value.start
		end := f.value.start + f.value.len
		for i < end {
			for i < end && (c.buf[i] == ` ` || c.buf[i] == `\t`) {
				i++
			}
			ks := i
			for i < end && c.buf[i] != `=` && c.buf[i] != `;` {
				i++
			}
			mut ke := i
			for ke > ks && (c.buf[ke - 1] == ` ` || c.buf[ke - 1] == `\t`) {
				ke--
			}
			mut vs := i
			mut ve := i
			if i < end && c.buf[i] == `=` {
				i++
				vs = i
				for i < end && c.buf[i] != `;` {
					i++
				}
				ve = i
				for vs < ve && (c.buf[vs] == ` ` || c.buf[vs] == `\t`) {
					vs++
				}
				for ve > vs && (c.buf[ve - 1] == ` ` || c.buf[ve - 1] == `\t`) {
					ve--
				}
				if ve - vs >= 2 && c.buf[vs] == `"` && c.buf[ve - 1] == `"` {
					vs++
					ve--
				}
			}
			if i < end {
				i++ // the ';'
			}
			if ke - ks == name.len && eq_at(c.buf, ks, name) {
				return str_view(c.buf, vs, ve - vs)
			}
		}
	}
	return none
}

// set_cookie adds a Set-Cookie header. A cookie whose name is not a token, or whose
// value, path or domain holds a character a cookie cannot carry, is dropped.
pub fn (mut c Ctx) set_cookie(ck Cookie) {
	if !valid_name(ck.name) || !valid_cookie_value(ck.value) || !valid_attr(ck.path)
		|| !valid_attr(ck.domain) {
		$if viltrum_debug ? {
			panic('viltrum: invalid cookie ${ck.name}')
		}
		return
	}
	c.hval_open()
	start := c.nhval
	c.hval_put(ck.name)
	c.hval_put('=')
	c.hval_put(ck.value)
	if ck.path.len > 0 {
		c.hval_put('; Path=')
		c.hval_put(ck.path)
	}
	if ck.domain.len > 0 {
		c.hval_put('; Domain=')
		c.hval_put(ck.domain)
	}
	if ck.max_age > 0 {
		c.hval_put('; Max-Age=')
		c.hval_int(ck.max_age)
	} else if ck.max_age < 0 {
		c.hval_put('; Max-Age=0')
	}
	if ck.secure || ck.same_site == .cross_site {
		c.hval_put('; Secure')
	}
	if ck.http_only {
		c.hval_put('; HttpOnly')
	}
	match ck.same_site {
		.lax { c.hval_put('; SameSite=Lax') }
		.strict { c.hval_put('; SameSite=Strict') }
		.cross_site { c.hval_put('; SameSite=None') }
		.unset {}
	}

	c.hval_header('Set-Cookie', start)
}

// clear_cookie tells the browser to drop cookie name now (Max-Age=0). Path and
// domain must match the ones it was set with.
pub fn (mut c Ctx) clear_cookie(ck Cookie) {
	c.set_cookie(Cookie{
		...ck
		value:   ''
		max_age: -1
	})
}

// cookie-octet (RFC 6265 4.1.1): visible ASCII except DQUOTE, comma, semicolon and backslash.
fn valid_cookie_value(v string) bool {
	for k in 0 .. v.len {
		b := v[k]
		if b < 0x21 || b > 0x7e || b == `"` || b == `,` || b == `;` || b == `\\` {
			return false
		}
	}
	return true
}

fn valid_attr(v string) bool {
	for k in 0 .. v.len {
		b := v[k]
		if b < 0x20 || b == 0x7f || b == `;` {
			return false
		}
	}
	return true
}

// --- the 405 Allow header ---

// set_allow adds the Allow header for a 405 from c.allow, the methods the router
// has for this path (the engine fills it in before a 405 chain runs).
pub fn (mut c Ctx) set_allow() {
	if c.allow == 0 {
		return
	}
	c.hval_open()
	start := c.nhval
	mut first := true
	for bit in 0 .. 10 {
		if c.allow & (u16(1) << bit) == 0 {
			continue
		}
		if !first {
			c.hval_put(', ')
		}
		m := unsafe { Method(bit) }
		c.hval_put(m.name())
		first = false
	}
	c.hval_header('Allow', start)
}

// --- header values built in place ---
//
// hval holds header values a helper composes (a Set-Cookie line, an Allow list). It
// is reused, never grown, so the views handed to set_header stay put. No header
// can point into it while nextra is 0, so that is when it starts over; begin()
// does not touch it, which keeps it off the path of every request.

fn (mut c Ctx) hval_open() {
	if c.nextra == 0 {
		c.nhval = 0
		c.hval_full = false
	}
}

fn (mut c Ctx) hval_put(s string) {
	if c.nhval + s.len > c.hval.len {
		c.hval_full = true
		return
	}
	unsafe { C.memcpy(&c.hval[c.nhval], s.str, s.len) }
	c.nhval += s.len
}

fn (mut c Ctx) hval_int(n int) {
	mut tmp := [12]u8{}
	end := unsafe { put_uint(&tmp[0], u64(n)) }
	c.hval_put(unsafe { tos(&tmp[0], int(end - &tmp[0])) })
}

// hval_header sets name to the value written since start, unless it did not fit.
fn (mut c Ctx) hval_header(name string, start int) {
	if c.hval_full {
		$if viltrum_debug ? {
			panic('viltrum: response header values over ${c.hval.len} bytes')
		}
		c.nhval = start
		c.hval_full = false
		return
	}
	c.set_header(name, unsafe { tos(&c.hval[start], c.nhval - start) })
}

fn eq_at(buf []u8, at int, s string) bool {
	for k in 0 .. s.len {
		if buf[at + k] != s[k] {
			return false
		}
	}
	return true
}
