# Static files

## Serving a directory

```v
mut app := viltrum.new()
app.static_files('/assets', './public')
app.static_files('/docs', './site', max_age: 3600, index: 'index.html')
```

`static_files(prefix, dir, opts)` registers `GET` and `HEAD` for `prefix/*filepath`; groups have it too
(`g.static_files`), behind the group's middleware. `/assets/css/app.css` answers with `./public/css/app.css`.

| `StaticOptions` | Default | |
|-----------------|---------|--|
| `index` | `'index.html'` | served for a directory; `''` answers 404 instead |
| `max_age` | `-1` | seconds for `Cache-Control: max-age`; `-1` sends no `Cache-Control` |
| `dotfiles` | `false` | serve names starting with `.` (`.env`, `.git/…`) |
| `precompressed` | `false` | serve `name.br` or `name.gz` beside a file to clients that accept it (see below) |

A directory requested without its trailing slash (`/docs/guide`) gets a 301 to `/docs/guide/`, query kept, so
relative links in its index resolve. Other methods answer 405 with `Allow: GET, HEAD`.

What never leaves `dir`: the rest of the path is percent-decoded name by name, and a name that is `.` or `..`,
or holds NUL or a backslash, answers 404 without opening anything. A decoded `%2F` separates names like `/`,
so `..%2F` is still `..`. Empty names (`//`) are collapsed. Dotfiles answer 404 unless `dotfiles` is set.
Symbolic links inside `dir` are followed, as nginx does by default: do not put a link to elsewhere in a served
tree unless you mean to serve it.

## One file from a handler

```v
app.get('/report', fn (mut c viltrum.Ctx) {
	c.file('/var/reports/latest.pdf', max_age: 60)
})
```

`c.file(path, opts)` answers with that file, `content_type` overriding the type picked from the extension.
A missing, unreadable or non-regular file answers 404.

## What a file answer carries

- `Content-Type` from the extension (html, css, js, json, svg, png, jpg, webp, avif, woff2, wasm, pdf, …;
  `application/octet-stream` otherwise), `Content-Length`, `Accept-Ranges: bytes`.
- `ETag` (from the file's mtime and size) and `Last-Modified`. `If-None-Match` (weak comparison, lists, `*`)
  or, without it, `If-Modified-Since` answer 304 with no body.
- One byte range on GET: `Range: bytes=0-99`, `bytes=100-`, `bytes=-100` answer 206 with `Content-Range`;
  a range that starts past the end answers 416 with `Content-Range: bytes */size`. Several ranges, or a
  malformed one, get the whole file (200), which RFC 9110 allows. `If-Range` with the current ETag or
  `Last-Modified` keeps the range; anything else sends the whole file.
- HEAD gets the same head and no body.

File answers bypass `gzip`: the body is not read into memory to be compressed, and a compressed body would no
longer match `Content-Range`.

Compressed copies made ahead of time are another matter. With `precompressed: true` (as nginx's
`gzip_static` and `brotli_static`), a request for `app.css` whose `Accept-Encoding` takes `br` gets
`app.css.br` if it exists, else one taking `gzip` gets `app.css.gz`, else `app.css` itself. The copy goes out
with the original's `Content-Type`, `Content-Encoding: br` or `gzip`, and its own ETag, and every answer from
such a route carries `Vary: Accept-Encoding` so caches keep the forms apart. Copies follow the disk like the
files themselves (see below): replace one and the next answer has the new bytes. Making them is up to
you (`brotli -k`, `gzip -k` at build time); viltrum never compresses a file.

```v
app.static_files('/assets', './public', precompressed: true, max_age: 86400)
```

## How it is sent

A file of 64 KB or less (`http1.file_inline_max`) is read into the response with its head and goes out in the
same write as any other response. A larger one is not read by the handler: the engine sends it after the head,
with `sendfile` on cleartext connections (from the page cache to the socket, no copy through user space) and
through the write buffer one piece at a time over TLS. Requests pipelined behind a file wait for all of it;
a client that stops reading is cut by `write_timeout`, and the file is closed with the connection.

`static_files` keeps the files it sends inline (and their `.br` / `.gz` copies) in memory, one copy per worker,
up to 4 MiB per worker (`http1.file_cache_max`); past that, files are read from disk as before. Each request
still runs one `stat` on the file it serves, and the copy is used only while size, mtime, inode and ctime are
what they were when it was read, so a file rewritten in place or replaced by a rename is read again by the next
request. A hit costs that one `stat` instead of `open`, `fstat`, `read` and `close`. One case escapes it: a
rewrite that keeps the size and lands within the filesystem's timestamp granularity (a few milliseconds) of the
write the copy was read after. On Windows, where `stat` has neither nanoseconds nor an inode, nothing is cached.
`Ctx.file` always reads from disk.

Opening or stat'ing a file is a blocking call on the worker, as in every event-loop server that serves from
disk; on a local filesystem that is microseconds. Do not serve from a network filesystem that can stall.

Serving a file allocates nothing once the worker's buffers and cache have grown (CI checks a small file, a
304, a range, a directory index and a streamed file).
