# Viltrum

HTTP framework for [V](https://vlang.io) — small surface, own engine, single binary.

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)

```
request → multi-read frame → parse → route → middleware → response
         (keep-alive loop)
```

Viltrum owns the TCP accept loop and HTTP/1.1 framing. You write handlers.

## Features (v0.2.1)

- HTTP/1.1 multi-read until headers complete + `Content-Length` body
- Keep-alive (HTTP/1.1 default); `Connection: close` honored
- Body / header size limits via `App.options(ServerOptions{...})`
- Router with `:param` → `req.param('id')`; trailing slashes normalized
- Query decode → `req.query_param('q')` (`%XX`, `+`)
- Middleware chain (logger)
- Response builder → `resp.header('X-Foo', 'bar')`
- Optional `app.set_ctx` / `shared` capture for state
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

See [examples/README.md](examples/README.md) for curl recipes.

## Example

```v
module main

import viltrum

fn hello(req viltrum.Request) viltrum.Response {
	name := req.param('name') or { 'world' }
	mut resp := viltrum.json(200, '{"message":"hello, ${name}"}')
	return resp.header('X-Powered-By', 'viltrum')
}

fn main() {
	mut app := viltrum.new()
	app.options(viltrum.ServerOptions{
		max_body_bytes: 512 * 1024
	})
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
| `examples/` | hello + rest |

## Tests

```bash
v test http/
```

## Status

**v0.2.1** — framing + keep-alive + polish. Fine for experiments; not production-hardened.

See [CHANGELOG.md](CHANGELOG.md).

| Next (v0.3) | Out of scope for now |
|-------------|----------------------|
| Benchmarks (`oha`) | HTTP/2 |
| Graceful shutdown | TLS (use a reverse proxy) |
| Recover middleware | WebSocket |
| | Body streaming |

## License

MIT — see [LICENSE](LICENSE).
