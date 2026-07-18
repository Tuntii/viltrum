# Viltrum

**Axum-style HTTP framework for [V](https://vlang.io) with its own engine.**

Not a veb wrapper. Not related to RustAPI. TCP accept → HTTP/1.1 parse → router → middleware → response, all in-tree.

```
engine/    TCP accept + read
http/      Request/Response + parse
service/   middleware helpers (optional)
router/    method + :param routes
viltrum.v  facade (App)
```

## Status

**v0.1.0 — engine PoC**

| Done | Not yet |
|------|---------|
| HTTP/1.1 parse (request-line, headers, Content-Length body) | HTTP/2, TLS, WebSocket |
| TCP server + per-conn tasks | keep-alive pipelining |
| Router (`GET/POST` + `:param`) | typed extractors |
| Middleware chain (logger) | graceful shutdown API |
| `text` / `json` responses | body streaming |

## Requirements

- V 0.4+ (`v version`)
- Linux/macOS (Windows untested)

Install V: https://github.com/vlang/v#installing-v-from-source

## Setup (local module)

```bash
# from this repo root
mkdir -p ~/.vmodules
ln -sfn "$(pwd)" ~/.vmodules/viltrum
```

## Hello

```bash
v run examples/hello
# GET http://127.0.0.1:8080/
# GET http://127.0.0.1:8080/health
# GET http://127.0.0.1:8080/hi/tunay
```

## App sketch

```v
module main

import viltrum

fn hello(req viltrum.Request) viltrum.Response {
    name := viltrum.param(req, 'name') or { 'world' }
    return viltrum.json(200, '{"hi":"${name}"}')
}

fn main() {
    mut app := viltrum.new()
    app.use(viltrum.logger)
    app.get('/hi/:name', hello)
    app.listen('127.0.0.1:8080') or { panic(err) }
}
```

## Tests

```bash
v test http/
```

## Roadmap (short)

1. keep-alive + multi-read until `\r\n\r\n`
2. shared app state
3. honest benchmarks vs veb (`oha`)
4. `vpm` publish when stable

## Non-goals (v0.x)

- Replacing veb for HTML apps
- Feature parity with Axum/Tower
- Production TLS termination (use a reverse proxy for now)

## License

MIT
