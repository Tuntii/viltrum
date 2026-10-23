module http1

// Form bodies: application/x-www-form-urlencoded and multipart/form-data (RFC 7578).
// The engine has already read the whole body (up to Limits.max_body_bytes), so a
// form is parsed in place: names, values and file contents are views into it, valid
// until the handler returns, and nothing is allocated.

// FormPart is one part of a multipart/form-data body.
pub struct FormPart {
pub:
	name         string
	filename     string // as the client sent it; see safe_filename
	content_type string // '' when the part has none (text/plain by RFC 7578)
	data         []u8
mut:
	file bool // the part has a filename parameter, even an empty one
}

// is_file reports whether the part is a file upload (it has a filename parameter;
// browsers send filename="" for a file input left empty).
pub fn (p FormPart) is_file() bool {
	return p.file
}

// safe_filename is the last path component of filename (after / or \), or none when
// that is empty, `.` or `..`, or holds a NUL. It is a view, not a sanitised copy:
// still check it against what your storage accepts before using it as a path.
pub fn (p FormPart) safe_filename() ?string {
	s := p.filename
	mut i := s.len
	for i > 0 && s[i - 1] != `/` && s[i - 1] != `\\` {
		i--
	}
	name := sub_view(s, i, s.len - i)
	if name.len == 0 || name == '.' || name == '..' || name.contains_u8(0) {
		return none
	}
	return name
}

// form_value returns the first field called name of a form body: a urlencoded
// field with %XX and '+' decoded, or a multipart part that is not a file, as sent.
pub fn (mut c Ctx) form_value(name string) ?string {
	ct := c.header('content-type') or { return none }
	if is_media(ct, 'application/x-www-form-urlencoded') {
		return c.pair_value(c.body_bytes, 0, c.body_bytes.len, name)
	}
	if is_media(ct, 'multipart/form-data') {
		mut it := c.form_parts()
		for {
			p := it.next() or { break }
			if !p.file && p.name == name {
				return str_view(p.data, 0, p.data.len)
			}
		}
	}
	return none
}

pub fn (mut c Ctx) form_int(name string) ?i64 {
	return parse_i64(c.form_value(name)?)
}

// form_file returns the first file part called name of a multipart/form-data body.
pub fn (c &Ctx) form_file(name string) ?FormPart {
	mut it := c.form_parts()
	for {
		p := it.next() or { break }
		if p.file && p.name == name {
			return p
		}
	}
	return none
}

// FormParts walks the parts of a multipart/form-data body in order.
pub struct FormParts {
	body []u8
	bnd  string
mut:
	pos  int // the next delimiter: "--" boundary
	done bool
	bad  bool
}

// form_parts walks the parts of a multipart/form-data body; for any other body it
// yields nothing.
//
//	mut it := c.form_parts()
//	for {
//		p := it.next() or { break }
//		...
//	}
pub fn (c &Ctx) form_parts() FormParts {
	ct := c.header('content-type') or { '' }
	if !is_media(ct, 'multipart/form-data') {
		return FormParts{
			done: true
		}
	}
	b := c.body_bytes
	bnd := media_param(ct, 'boundary')
	mut pos := -1
	if bnd.len > 0 && bnd.len <= 70 {
		if delim_at(b, 0, bnd) {
			pos = 0 // no preamble: the first delimiter has no CRLF before it
		} else {
			d := find_delim(b, 0, bnd)
			if d >= 0 {
				pos = d + 2
			}
		}
	}
	return FormParts{
		body: b
		bnd:  bnd
		pos:  pos
		done: pos < 0
		bad:  pos < 0
	}
}

// malformed reports whether the walk stopped at a body that does not follow RFC 2046
// (no boundary, a part without a delimiter after it); the parts before it were
// returned.
pub fn (it &FormParts) malformed() bool {
	return it.bad
}

pub fn (mut it FormParts) next() ?FormPart {
	b := it.body
	for !it.done {
		mut p := it.pos + 2 + it.bnd.len
		if p + 1 < b.len && b[p] == `-` && b[p + 1] == `-` {
			it.done = true // the close delimiter; the epilogue is ignored
			break
		}
		for p < b.len && (b[p] == ` ` || b[p] == `\t`) {
			p++
		}
		if p + 1 >= b.len || b[p] != `\r` || b[p + 1] != `\n` {
			return it.stop()
		}
		p += 2
		mut disp := Span{}
		mut ctype := Span{}
		for {
			e := crlf_from(b, p)
			if e < 0 {
				return it.stop()
			}
			if e == p {
				p += 2
				break
			}
			mut colon := p
			for colon < e && b[colon] != `:` {
				colon++
			}
			if colon < e {
				nm := str_view(b, p, colon - p)
				if eq_ci(nm, 'content-disposition') {
					disp = trimmed(b, colon + 1, e)
				} else if eq_ci(nm, 'content-type') {
					ctype = trimmed(b, colon + 1, e)
				}
			}
			p = e + 2
		}
		d := find_delim(b, p, it.bnd)
		if d < 0 {
			return it.stop()
		}
		it.pos = d + 2
		dv := if disp.found() { str_view(b, disp.start, disp.len) } else { '' }
		if !is_media(dv, 'form-data') {
			continue // RFC 7578 parts are all form-data; skip anything else
		}
		name := param_span(dv, 'name')
		fname := param_span(dv, 'filename')
		return FormPart{
			name:         if name.found() { sub_view(dv, name.start, name.len) } else { '' }
			filename:     if fname.found() { sub_view(dv, fname.start, fname.len) } else { '' }
			file:         fname.found()
			content_type: if ctype.found() { str_view(b, ctype.start, ctype.len) } else { '' }
			data:         view(b, p, d - p)
		}
	}
	return none
}

fn (mut it FormParts) stop() ?FormPart {
	it.done = true
	it.bad = true
	return none
}

// delim_at reports whether b[i..] starts with "--" boundary.
@[direct_array_access]
fn delim_at(b []u8, i int, bnd string) bool {
	if i + 2 + bnd.len > b.len || b[i] != `-` || b[i + 1] != `-` {
		return false
	}
	return unsafe { C.memcmp(&u8(b.data) + i + 2, bnd.str, bnd.len) } == 0
}

// find_delim returns the index of the CR of the first CRLF "--" boundary at or after
// from, or -1.
@[direct_array_access]
fn find_delim(b []u8, from int, bnd string) int {
	mut i := from
	for i + 4 + bnd.len <= b.len {
		p := unsafe { C.memchr(&u8(b.data) + i, `\r`, usize(b.len - i)) }
		if isnil(p) {
			return -1
		}
		i = int(unsafe { &u8(p) - &u8(b.data) })
		if i + 1 < b.len && b[i + 1] == `\n` && delim_at(b, i + 2, bnd) {
			return i
		}
		i++
	}
	return -1
}

// crlf_from returns the index of the first CRLF at or after i, or -1.
@[direct_array_access]
fn crlf_from(b []u8, i int) int {
	mut k := i
	for k + 1 < b.len {
		if b[k] == `\r` && b[k + 1] == `\n` {
			return k
		}
		k++
	}
	return -1
}

// trimmed is b[s..e] without the spaces and tabs around it.
@[direct_array_access]
fn trimmed(b []u8, s int, e int) Span {
	mut i := s
	mut j := e
	for i < j && (b[i] == ` ` || b[i] == `\t`) {
		i++
	}
	for j > i && (b[j - 1] == ` ` || b[j - 1] == `\t`) {
		j--
	}
	return Span{
		start: i
		len:   j - i
	}
}

// is_media reports whether a Content-Type (or Content-Disposition) value names the
// type lower_lit, ignoring case and any parameters.
fn is_media(v string, lower_lit string) bool {
	if v.len < lower_lit.len || !eq_ci(sub_view(v, 0, lower_lit.len), lower_lit) {
		return false
	}
	if v.len == lower_lit.len {
		return true
	}
	c := v[lower_lit.len]
	return c == `;` || c == ` ` || c == `\t`
}

// media_param returns the value of the parameter called lower_lit, or ''.
fn media_param(v string, lower_lit string) string {
	s := param_span(v, lower_lit)
	return if s.found() { sub_view(v, s.start, s.len) } else { '' }
}

// param_span finds the parameter called lower_lit (any case) among the `;`-separated
// parameters of a header value and returns its value without quotes. A quoted value
// ends at the next quote: browsers percent-encode quotes in names and filenames
// rather than escape them, and send backslashes as they are.
@[direct_array_access]
fn param_span(v string, lower_lit string) Span {
	mut i := 0
	for i < v.len && v[i] != `;` {
		i++
	}
	for i < v.len {
		i++ // past `;`
		for i < v.len && (v[i] == ` ` || v[i] == `\t`) {
			i++
		}
		ks := i
		for i < v.len && v[i] != `=` && v[i] != `;` {
			i++
		}
		mut ke := i
		for ke > ks && (v[ke - 1] == ` ` || v[ke - 1] == `\t`) {
			ke--
		}
		mut val := Span{
			start: i
			len:   0
		}
		if i < v.len && v[i] == `=` {
			i++
			for i < v.len && (v[i] == ` ` || v[i] == `\t`) {
				i++
			}
			if i < v.len && v[i] == `"` {
				i++
				vs := i
				for i < v.len && v[i] != `"` {
					i++
				}
				val = Span{
					start: vs
					len:   i - vs
				}
				for i < v.len && v[i] != `;` {
					i++
				}
			} else {
				vs := i
				for i < v.len && v[i] != `;` {
					i++
				}
				mut ve := i
				for ve > vs && (v[ve - 1] == ` ` || v[ve - 1] == `\t`) {
					ve--
				}
				val = Span{
					start: vs
					len:   ve - vs
				}
			}
		}
		if eq_ci(sub_view(v, ks, ke - ks), lower_lit) {
			return val
		}
	}
	return Span{}
}
