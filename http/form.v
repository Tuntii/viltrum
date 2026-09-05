module http

// URL-encoded and multipart/form-data helpers.
// Minimal: no nested multipart, no streaming, no disk writes.

const default_max_parts = 64
const default_max_part_bytes = 1 * 1024 * 1024

// FormOptions caps multipart parsing. 0 on a field means no extra cap
// (the request body is still bound by ServerOptions.max_body_bytes).
pub struct FormOptions {
pub:
	max_parts      int = default_max_parts
	max_part_bytes int = default_max_part_bytes
}

// FormPart is one multipart field. filename empty → ordinary field.
pub struct FormPart {
pub:
	name         string
	filename     string
	content_type string
	data         []u8
}

// safe_filename is the last path component of filename, or none if empty
// or the remaining name is `.` / `..`. `a/b.txt` → `b.txt`.
pub fn (p FormPart) safe_filename() ?string {
	return sanitize_filename(p.filename)
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

// form_parts parses multipart/form-data with default FormOptions.
// Errors if Content-Type is not multipart, the body is malformed, or a limit is hit.
pub fn (r &Request) form_parts() ![]FormPart {
	return r.form_parts_opts(FormOptions{})
}

// form_parts_opts is form_parts with explicit part-count / per-part size caps.
pub fn (r &Request) form_parts_opts(opts FormOptions) ![]FormPart {
	ct := r.headers.get_or_lowered('content-type', '')
	if !ct_has_multipart(ct) {
		return error('not multipart/form-data')
	}
	return parse_multipart_opts(r.body, ct, opts)
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
	return parse_multipart_opts(body, content_type, FormOptions{})
}

fn parse_multipart_opts(body []u8, content_type string, opts FormOptions) ![]FormPart {
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
		part_len := if body_end > body_start { body_end - body_start } else { 0 }
		if opts.max_part_bytes > 0 && part_len > opts.max_part_bytes {
			return error('multipart: part too large (max ${opts.max_part_bytes} bytes)')
		}
		if opts.max_parts > 0 && parts.len >= opts.max_parts {
			return error('multipart: too many parts (max ${opts.max_parts})')
		}
		mut data := []u8{}
		if part_len > 0 {
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

fn sanitize_filename(raw string) ?string {
	if raw.len == 0 {
		return none
	}
	mut s := raw.replace('\\', '/')
	if slash := s.last_index('/') {
		s = s[slash + 1..]
	}
	if s.len == 0 || s == '.' || s == '..' {
		return none
	}
	if s.contains('\0') {
		return none
	}
	return s
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
