# Forms and uploads

```v
app.post('/signup', fn (mut c viltrum.Ctx) {
	name := c.form_value('name') or { '' }
	age := c.form_int('age') or { 0 }
	c.text(200, 'hello ${name} (${age})')
})

app.post('/upload', fn (mut c viltrum.Ctx) {
	f := c.form_file('doc') or {
		c.text(400, 'no file')
		return
	}
	name := f.safe_filename() or { 'upload.bin' }
	os.write_file_array(os.join_path('uploads', name), f.data) or {
		c.text(500, 'cannot store it')
		return
	}
	c.text(201, '${f.data.len} bytes')
})
```

| Call | Returns |
|------|---------|
| `c.form_value('name')`, `c.form_int('n')` | first field of a form body: urlencoded with `%XX` and `+` decoded, or a multipart part that is not a file, as sent |
| `c.form_file('doc')` | first file part of a `multipart/form-data` body, as a `FormPart` |
| `c.form_parts()` | iterator over every multipart part in order (repeated names, several files) |

The body is read by `Content-Type`: `application/x-www-form-urlencoded` or `multipart/form-data` (any case,
parameters such as `charset` ignored). Any other body has no form fields. The query string is not part of the
form; read it with `c.query_param`.

## `FormPart`

| Field | |
|-------|--|
| `name` | the field name |
| `filename` | as the client sent it, path and all; `''` when there is none |
| `content_type` | the part's `Content-Type`, `''` when absent |
| `data` | the part's bytes |
| `is_file()` | the part has a `filename` parameter (browsers send `filename=""` for an empty file input) |
| `safe_filename()` | the last component of `filename` after `/` or `\`, or none for `''`, `.`, `..` or a NUL |

`safe_filename` keeps a client from naming a path outside your upload directory, nothing more: check the name
against what your storage accepts, or store under a name you choose.

```v
mut it := c.form_parts()
for {
	p := it.next() or { break }
	if p.is_file() {
		println('${p.name}: ${p.filename}, ${p.data.len} bytes')
	}
}
if it.malformed() {
	c.text(400, 'bad multipart body')
	return
}
```

`malformed()` is true when the walk stopped at a body that does not follow RFC 2046 (no `boundary`, a part
with no delimiter after it); the parts before the damage were returned. Parts whose `Content-Disposition` is
not `form-data` are skipped. Quoted names and filenames end at the next quote, which is how browsers send them
(they percent-encode quotes and newlines in filenames, and send backslashes as they are). `filename*` is
ignored, as RFC 7578 says.

## Limits and lifetime

Forms are parsed in place, without allocating: every string and `data` slice is a view into the request,
valid until the handler returns. Copy (`.clone()`) what you keep, or write it out before returning.

The whole body is in memory before the handler runs, so an upload is bound by `Options.limits.max_body_bytes`
(1 MiB by default). Raise it for larger uploads:

```v
import viltrum.http1

app.server_options(viltrum.Options{
	limits: http1.Limits{
		max_body_bytes: 32 * 1024 * 1024
	}
})
```

Each connection's read buffer grows to hold its largest request and shrinks back when the connection closes,
so the limit is also how much memory one client can make a worker hold. A body over the limit is refused with
413 before it is read; the engine then reads and drops what the client still sends for a while (a lingering
close, see [connection.md](./connection.md)), so a client that writes its whole upload before reading gets
the 413 rather than a reset connection. Streaming uploads to disk as they arrive is not supported.
