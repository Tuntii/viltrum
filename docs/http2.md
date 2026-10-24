# HTTP/2 (`h2c`)

Viltrum serves HTTP/2 from the same epoll workers as HTTP/1.1, through the same router, middleware and `Ctx`:
a handler does not know which protocol it answers. This release serves **cleartext HTTP/2 with prior
knowledge** (h2c), the form reverse proxies, load balancers and service meshes speak to the applications
behind them. HTTP/2 over TLS, chosen by ALPN, comes next.

## Quick start

```v
mut app := viltrum.new()
app.get('/', fn (mut c viltrum.Ctx) {
	c.text(200, 'ok\n')
})
app.serve([
	viltrum.Listener{
		addr:  '0.0.0.0:8080'
		http2: true
	},
])!
```

```bash
curl --http2-prior-knowledge http://127.0.0.1:8080/   # HTTP/2
curl http://127.0.0.1:8080/                           # HTTP/1.1, same port
```

A listener with `http2` set reads the first bytes of each connection: the HTTP/2 connection preface makes it an
HTTP/2 connection, anything else is served as HTTP/1.1 (RFC 9113 3.3, as nginx and h2o do). The
`Upgrade: h2c` route from HTTP/1.1 is not offered; RFC 9113 deprecated it.

## API

| Symbol | Role |
|--------|------|
| `Listener{ addr, http2: true }` | a cleartext listener that serves HTTP/2 to clients that start with its preface, and HTTP/1.1 to the rest |

`http2` on a TLS listener does nothing yet.

## What a handler sees

The same `Ctx` as over HTTP/1.1. Specifically:

- `:authority` is the `Host` header, `:method` and `:path` are `c.method()`, `c.path()` and `c.query()`.
- Cookies sent as several `cookie` fields read as one, joined with `; ` (RFC 9113 8.2.3).
- The body is the stream's DATA, whole, when the handler runs; `max_body_bytes` holds as it does over HTTP/1.1.
- Response headers go out lowercase. `Connection`, `Keep-Alive`, `Transfer-Encoding` and `Upgrade` are
  dropped (they have no meaning in HTTP/2). `c.close()` does not close an HTTP/2 connection.
- Files (`c.file`, `app.static_files`) stream from disk as the client's flow-control windows allow.

Not served over HTTP/2 yet, answered **501** instead: deferred responses (`c.after`) and WebSocket upgrades.
Use HTTP/1.1 for those routes.

## Limits

Each holds per connection; going past one ends what it says, the rest of the connection carries on unless
noted.

| Limit | Value | Past it |
|-------|-------|---------|
| Concurrent streams | 128 (announced in SETTINGS) | the stream is refused (REFUSED_STREAM) |
| Header list (decoded) | `Limits.max_header_bytes` (64 KiB) | **431** on that stream; four times past it, the connection ends (COMPRESSION_ERROR) |
| Header block, across CONTINUATION frames | `max_header_bytes`, 32 frames | the connection ends (ENHANCE_YOUR_CALM) |
| Request body | `Limits.max_body_bytes` (1 MiB) | **413**, and the stream is reset |
| Bodies held at once | each stream's window starts at 64 KiB and reopens as its body is read; while the bodies held pass `max_body_bytes`, only the oldest stream's window reopens | the other streams wait, never fail |
| Responses waiting on the client's windows | `Options.max_pending` (1 MiB) of bodies, 32 files | new streams are refused (REFUSED_STREAM, which clients retry) |
| A client that never opens its windows | `Options.write_timeout`, counted from when the waiting output last moved | the connection is closed |
| Frame size | 16 KiB (the default; we never raise it) | the connection ends (FRAME_SIZE_ERROR) |
| Control frames between answered requests (PING, SETTINGS, PRIORITY, RST_STREAM, empty DATA, unknown types) | 1000 | the connection ends (ENHANCE_YOUR_CALM) |
| HPACK dynamic table | 4096 bytes, both ways | |

A malformed request (pseudo-headers missing, repeated or after a regular field, an uppercase or connection-
specific field name, a value with CR, LF or NUL, a `content-length` that disagrees with the DATA) resets its
stream with PROTOCOL_ERROR, as RFC 9113 8.1.1 asks. A request that passes those checks still goes through the
HTTP/1.1 head parser, so every rule a request is held to there holds here too.

## How it is checked

- Every example of RFC 7541 (HPACK) Appendix C, both directions; HPACK and frame handling fuzzed in CI.
- [h2spec](https://github.com/summerwind/h2spec) 2.6.0 (`bash benches/h2spec/run.sh`): 144 of 146 pass, one is
  skipped. The one failure is "invalid connection
  preface": the test sends `INVALID CONNECTION PREFACE`, which a listener that also serves HTTP/1.1 reads as a
  bad HTTP/1.1 request and answers 400. A preface that starts `PRI * HTTP/2.0` and then goes wrong gets the
  GOAWAY the test expects.
- curl and h2load as clients; HTTP/2 requests allocate nothing once a worker is warm, as HTTP/1.1 ones do (the
  zero-allocation gate covers both).

Design notes: [design/1.x-http2.md](./design/1.x-http2.md).
