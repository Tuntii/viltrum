module http

// URL-encoded and multipart/form-data helpers.
// Minimal: no nested multipart, no streaming, no filename sanitizing.

// FormPart is one multipart field. filename empty → ordinary field.
pub struct FormPart {
pub:
	name         string
	filename     string
	content_type string
	data         []u8
}

// form_value returns a urlencoded field or a multipart text field (no filename).
pub fn (r &Request) form_value(name string) ?string {
	ct := r.headers.get_or_lowered('content-type', '')
	if ct_has_multipart(ct) {
		parts := parse_multipart(r.body, ct) or { return none }
		for p in parts {
			if p.name == name && p.filename.len == 0 {
				return p.data.bytestr()
			}
		}
		return none
	}
	return form_urlencoded_get(r.text(), name)
}

// form_file returns the first multipart file part with this field name.
pub fn (r &Request) form_file(name string) ?FormPart {
	ct := r.headers.get_or_lowered('content-type', '')
	if !ct_has_multipart(ct) {
		return none
	}
	parts := parse_multipart(r.body, ct) or { return none }
	for p in parts {
		if p.name == name && p.filename.len > 0 {
			return p
		}
	}
	return none
}

// form_parts parses multipart/form-data. Errors if Content-Type is not multipart
// or the body is malformed.
pub fn (r &Request) form_parts() ![]FormPart {
	ct := r.headers.get_or_lowered('content-type', '')
	if !ct_has_multipart(ct) {
		return error('not multipart/form-data')
	}
	return parse_multipart(r.body, ct)
}

fn ct_has_multipart(ct string) bool {
	return ct.to_lower().contains('multipart/form-data')
}

fn form_urlencoded_get(raw string, name string) ?string {
	for part in raw.split('&') {
		if part.len == 0 {
			continue
		}
		eq := part.index('=') or {
			k := url_decode(part) or { part }
			if k == name {
				return ''
			}
			continue
		}
		k := url_decode(part[..eq]) or { part[..eq] }
		if k == name {
			return url_decode(part[eq + 1..]) or { part[eq + 1..] }
		}
	}
	return none
}

fn parse_multipart(body []u8, content_type string) ![]FormPart {
	boundary := multipart_boundary(content_type) or { return error('multipart: missing boundary') }
	if boundary.len == 0 {
		return error('multipart: empty boundary')
	}
	delim := '--${boundary}'.bytes()
	mut parts := []FormPart{}
	mut pos := 0
	// First delimiter
	idx := find_bytes(body, delim, pos) or { return error('multipart: no first boundary') }
	pos = idx + delim.len
	for {
		if pos + 1 < body.len && body[pos] == `-` && body[pos + 1] == `-` {
			break // closing --
		}
		// skip CRLF after boundary
		if pos + 1 < body.len && body[pos] == `\r` && body[pos + 1] == `\n` {
			pos += 2
		} else if pos < body.len && body[pos] == `\n` {
			pos++
		}
		sep := find_bytes(body, '\r\n\r\n'.bytes(), pos) or {
			return error('multipart: part missing header/body separator')
		}
		hdr := body[pos..sep].bytestr()
		body_start := sep + 4
		next := find_bytes(body, delim, body_start) or { return error('multipart: unterminated part') }
		// body is bytes before \r\n + delim (or just delim)
		mut body_end := next
		if body_end >= 2 && body[body_end - 2] == `\r` && body[body_end - 1] == `\n` {
			body_end -= 2
		}
		mut data := []u8{}
		if body_end > body_start {
			data = body[body_start..body_end].clone()
		}
		name, filename := parse_content_disposition(hdr)
		if name.len == 0 {
			return error('multipart: part missing name')
		}
		parts << FormPart{
			name:         name
			filename:     filename
			content_type: header_line_value(hdr, 'content-type')
			data:         data
		}
		pos = next + delim.len
	}
	return parts
}

fn multipart_boundary(content_type string) ?string {
	lower := content_type.to_lower()
	key := 'boundary='
	idx := lower.index(key) or { return none }
	mut raw := content_type[idx + key.len..].trim_space()
	// strip trailing parameters after ;
	if sc := raw.index(';') {
		raw = raw[..sc].trim_space()
	}
	if raw.starts_with('"') && raw.ends_with('"') && raw.len >= 2 {
		raw = raw[1..raw.len - 1]
	}
	if raw.len == 0 {
		return none
	}
	return raw
}

fn parse_content_disposition(hdr string) (string, string) {
	line := header_line_value(hdr, 'content-disposition')
	return disp_param(line, 'name'), disp_param(line, 'filename')
}

fn header_line_value(hdr string, name_lower string) string {
	for raw in hdr.replace('\r\n', '\n').split('\n') {
		line := raw.trim_space()
		colon := line.index(':') or { continue }
		k := line[..colon].trim_space().to_lower()
		if k == name_lower {
			return line[colon + 1..].trim_space()
		}
	}
	return ''
}

fn disp_param(line string, key string) string {
	needle := '${key}='
	// case-insensitive search
	lower := line.to_lower()
	idx := lower.index(needle) or { return '' }
	mut raw := line[idx + needle.len..].trim_space()
	if raw.starts_with('"') {
		mut j := 1
		for j < raw.len {
			if raw[j] == `"` {
				return raw[1..j]
			}
			j++
		}
		return raw[1..]
	}
	// unquoted until ; or end
	mut i := 0
	for i < raw.len {
		if raw[i] == `;` || raw[i] == ` ` {
			break
		}
		i++
	}
	return raw[..i]
}

fn find_bytes(hay []u8, needle []u8, from int) ?int {
	if needle.len == 0 || from < 0 {
		return none
	}
	limit := hay.len - needle.len
	if from > limit {
		return none
	}
	for i in from .. limit + 1 {
		mut ok := true
		for j in 0 .. needle.len {
			if hay[i + j] != needle[j] {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return none
}
