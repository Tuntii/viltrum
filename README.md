# Viltrum

HTTP framework for [V](https://vlang.io) — small surface, own engine, single binary.

```
request → multi-read frame → parse → route → middleware → response
         (keep-alive loop)
```

Viltrum owns the TCP accept loop and HTTP/1.1 framing. You write handlers.

## Features (v0.2)

- HTTP/1.1 multi-read until headers complete + `Content-Length` body
- Keep-alive (HTTP/1.1 default); `Connection: close` honored
- Body / header size limits
- Router with method match and `:param` → `req.param('id')`
- Query helper → `req.query_param('q')`
- Middleware chain (logger)
- Optional `app.set_ctx` voidptr (or capture `shared` state in closures)
- `text` / `json` / `empty` helpers
- Zero external deps beyond V stdlib

## Quick start

**1. Install V** — https://github.com/vlang/v#installing-v-from-source

**2. Link the module**

```bash
git clone https://github.com/Tuntii/viltrum.git
cd viltrum
mkdir -p ~/.vmodules
ln -sfn "$(pwd)" ~/.vmodules/viltrum
```

**3. Run examples**

```bash
v run examples/hello   # :8080
v run examples/rest    # :8081  JSON todos
```

```text
GET  http://127.0.0.1:8080/hi/tunay
GET  http://127.0.0.1:8081/todos
POST http://127.0.0.1:8081/todos  {"title":"ship"}
```

## Example

```v
module main

import viltrum

fn hello(req viltrum.Request) viltrum.Response {
	name := req.param('name') or { 'world' }
	return viltrum.json(200, '{"message":"hello, ${name}"}')
}

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.logger)
	app.get('/hi/:name', hello)
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

## Layout

| Path | Role |
|------|------|
| `engine/` | TCP listen, multi-read framing, keep-alive |
| `http/` | `Request` / `Response`, parse & serialize |
| `router/` | Method + path routing, params |
| `service/` | Shared middleware helpers |
| `viltrum.v` | Public `App` API |
| `examples/hello/` | Minimal server |
| `examples/rest/` | In-memory TODO JSON API |

## Tests

```bash
v test http/
```

## Status

**v0.2** — real HTTP/1.1 framing + keep-alive. Fine for experiments; not production-hardened.

| Next (v0.3) | Out of scope for now |
|-------------|----------------------|
| Benchmarks (`oha`) | HTTP/2 |
| More parse edge-case tests | TLS (use a reverse proxy) |
| Graceful shutdown | WebSocket |
| Query map helpers polish | Body streaming |

## License

MIT — see [LICENSE](LICENSE).
