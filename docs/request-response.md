# Request and response

## Request (`Ctx`)

| Call | Returns |
|------|---------|
| `c.method()`, `c.method_name()` | `Method` enum (`.get`, `.post`, …, `.other`) / the method as sent (`'GET'`, `'PROPFIND'`); `Method.name()` gives `'GET'` for an enum value |
| `c.path()`, `c.query()` | raw path (no query) and raw query string |
| `c.param('id')`, `c.param_int('id')` | route params |
| `c.query_param('q')`, `c.query_int('n')` | first query value, `%XX` and `+` decoded |
| `c.header('name')`, `c.header_values('name')` | first field (any case) / iterator over repeated fields |
| `c.cookie('name')` | a request cookie's value (every `Cookie` header searched, quotes removed) |
| `c.body()`, `c.body_text()`, `c.body_int()` | body bytes (chunked bodies arrive decoded) / the same as a string view, for decoders: `json.decode(User, c.body_text())` |
| `c.form_value('f')`, `c.form_int('n')`, `c.form_file('doc')`, `c.form_parts()` | urlencoded and multipart forms ([forms.md](./forms.md)) |
| `c.worker_id()` | index of the worker thread |

Every string and slice above is a view into connection buffers, valid until the handler returns. Clone what
you keep. Build with `-d viltrum_debug` to overwrite request bytes after each request, so a kept view shows up
as garbage in tests.

## Response

`c.text(status, s)`, `c.text_int(status, n)`, `c.json(status, value)`, `c.html(status, s)`,
`c.bytes(status, content_type, data)`, `c.no_content(status)`, `c.redirect(status, location)`, `c.file(path)`
(see [files.md](./files.md)). Add headers first with `c.set_header(name, value)` (up to 16) and call `c.close()` first
to close the connection after the response. One response per request; a second call is ignored (it panics in
`-d viltrum_debug` builds).

The framework writes `Content-Length`, `Date` (on by default) and `Server` (if `Options.server_header` is set).
HEAD answers keep `Content-Length` and drop the body. A 405 carries `Allow` with the methods the path has.

### HTML, redirects, cookies

```v
app.post('/login', fn (mut c viltrum.Ctx) {
	// ...check the form...
	c.set_cookie(name: 'session', value: token, max_age: 7 * 24 * 3600)
	c.redirect(303, '/items') // 303: the browser follows a form POST with a GET
})

app.get('/items', fn (mut c viltrum.Ctx) {
	token := c.cookie('session') or {
		c.redirect(303, '/login')
		return
	}
	c.html(200, render_items(token))
})

app.post('/logout', fn (mut c viltrum.Ctx) {
	c.clear_cookie(name: 'session')
	c.redirect(303, '/login')
})
```

- `c.html(status, s)` answers `text/html; charset=utf-8`.
- `c.redirect(status, location)` answers 301, 302, 303, 307 or 308 with `Location` and an empty body. A location
  holding CR or LF is dropped, like any header value.
- `c.set_cookie(viltrum.Cookie{...})` adds a `Set-Cookie`. The defaults are the safe ones for a session:
  `Path=/`, `HttpOnly`, `SameSite=Lax`. `max_age` in seconds (0 keeps it a session cookie), `secure`, `domain`,
  `same_site: .strict | .lax | .cross_site | .unset` (`.cross_site` is `SameSite=None` and always sends
  `Secure`, which browsers require for it). A cookie whose name, value, path or domain could not travel in a
  cookie is dropped. `c.clear_cookie(name: ..., path: ...)` sends it again with `Max-Age=0`.

These compose their header values in a 512-byte buffer inside the `Ctx`, so they allocate nothing; a response
whose composed headers exceed it drops the one that did not fit (panics under `-d viltrum_debug`).

## Deferred responses

`c.after(ms, cb, arg)` answers later without holding the worker: the handler returns at once, and no sooner
than `ms` milliseconds on, `cb(mut c, arg)` runs on the same worker and writes the response (it may call
`after` again). `cb` has the type `fn (mut c Ctx, arg u64)`; a plain function or a closure without captures
keeps the path allocation-free.

```v
fn done(mut c viltrum.Ctx, ms u64) {
	c.text_int(200, i64(ms))
}

app.get('/delay/:ms', fn (mut c viltrum.Ctx) {
	ms := c.param_int('ms') or { 0 }
	c.after(int(ms), done, u64(ms))
})
```

By the time `cb` runs the request is gone: path, params, headers and body read empty, and headers set before
`after` are dropped, so pass what `cb` needs in `arg` (a value, or an index into your own per-worker state).
Requests pipelined behind a deferred one wait their turn, the connection's timeouts pause while it waits, and
a connection that closes first simply drops its response. Over HTTP/2 only the request's own stream waits;
the connection's other streams are answered meanwhile ([docs/http2.md](http2.md)). Middleware that runs after `c.next()` sees no
response yet, so a deferred response is not gzipped. `ms <= 0` calls `cb` right away. Timers have millisecond
granularity and round up.

## Middleware

`recover`, `gzip`, `cors` and `logger` are plain `fn (mut c Ctx)` middleware. `gzip` compresses text and JSON bodies of 256 bytes or more with viltrum's own DEFLATE encoder (`http1/deflate.v`, no C library), tuned for response-sized bodies. V cannot catch panics: a panic exits the process. `recover` only turns a handler that wrote no response into 500 and closes the connection. Run the server under a supervisor (e.g. systemd `Restart=always`).

## Handlers and `-prod`

V 0.5.2 `-prod` builds (with the default Boehm GC) wrap every call statement in a walk over each local struct
or array that holds pointers. Past 32 pointers that walk also takes the GC's global lock, so a handler that
keeps a large array of structs in a local variable and then calls functions serializes all workers. Keep large
data captured by the closure or behind a pointer, and keep handler locals scalar; `benches/httparena/main.v`
shows the shape. The framework's own hot path is checked for this in CI (`scripts/gcpin_check.sh`).
