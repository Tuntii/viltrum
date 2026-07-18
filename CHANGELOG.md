# Changelog

## 0.2.1 — 2026-07-18

Polish release on top of v0.2 framing.

- `App.options(ServerOptions)` — timeouts, body/header limits, `require_host`
- Query decode: `%XX` and `+` in `req.query_param`
- Trailing slash normalize (`/todos/` → `/todos`)
- Duplicate headers combined with `, `
- Response builder: `resp.header(name, value)`
- Engine: full write loop, consistent 413/400 + `Connection: close`
- HTTP/1.1 missing `Host` → 400 (when `require_host`)
- `app.route(method, path, handler)`
- More parse/unit tests, CI workflow, examples README

## 0.2.0 — 2026-07-18

- Multi-read headers + Content-Length body
- HTTP/1.1 keep-alive
- `req.param` / path params
- `examples/rest` in-memory TODO API
- Size limits (header/body)

## 0.1.0 — 2026-07-18

- Initial engine PoC: TCP accept, parse, router, middleware, hello example
