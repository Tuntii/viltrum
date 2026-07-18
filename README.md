# Viltrum

HTTP framework for [V](https://vlang.io) — small surface, own engine, single binary.

```
request → parse → route → middleware → response
```

Viltrum owns the TCP accept loop and HTTP/1.1 parsing. You write handlers; the rest stays in-tree.

## Features (v0.1)

- HTTP/1.1 request parsing (method, path, query, headers, `Content-Length` body)
- Router with method match and `:param` segments
- Middleware chain (e.g. request logger)
- `text` / `json` helpers
- Zero external dependencies beyond the V standard library

## Quick start

**1. Install V** — https://github.com/vlang/v#installing-v-from-source

**2. Link the module**

```bash
git clone https://github.com/Tuntii/viltrum.git
cd viltrum
mkdir -p ~/.vmodules
ln -sfn "$(pwd)" ~/.vmodules/viltrum
```

**3. Run the example**

```bash
v run examples/hello
```

```text
GET  http://127.0.0.1:8080/
GET  http://127.0.0.1:8080/health
GET  http://127.0.0.1:8080/hi/tunay
```

## Example

```v
module main

import viltrum

fn hello(req viltrum.Request) viltrum.Response {
	name := viltrum.param(req, 'name') or { 'world' }
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
| `engine/` | TCP listen, accept, per-connection read/write |
| `http/` | `Request` / `Response`, parse & serialize |
| `router/` | Method + path routing, params |
| `service/` | Shared middleware helpers |
| `viltrum.v` | Public `App` API |
| `examples/hello/` | Minimal server |

## Tests

```bash
v test http/
```

## Status

Early **v0.1** — usable for experiments and learning the stack. Not production-hardened.

| In scope soon | Out of scope for now |
|---------------|----------------------|
| Keep-alive / full header read loop | HTTP/2 |
| Shared application state | TLS (put a reverse proxy in front) |
| Cleaner param API | WebSocket |
| Benchmarks | Body streaming |

## License

MIT — see [LICENSE](LICENSE).
