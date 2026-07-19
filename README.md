# Viltrum

HTTP framework for [V](https://vlang.io). Small surface, own engine, single binary.

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)

## Install

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh   # links ~/.vmodules/viltrum
v run examples/hello
```

Requires [V](https://github.com/vlang/v) on PATH.

## Features (v0.5)

- Own TCP + HTTP/1.1 engine (keep-alive, idle timeout, graceful shutdown)
- **`app.upgrade` + `Conn`** — connection hijack for custom protocols
- **`app.ws` / first-party WebSocket** — RFC 6455 cleartext `ws://` on the same Conn path (`viltrum.ws`)
- Router: `:param`, trailing `*wildcard`, slash normalize; HEAD falls back to GET
- `app.mount` groups + `Mount.use` middleware
- `viltrum.chain` for route-level middleware
- Method helpers: `get` / `post` / `put` / `patch` / `delete` / `options` / `head`
- `cors`, `static_files`, `logger`, `recover`
- `req.json_string` / `json_int` / `json_bool` (minimal body helpers)
- `max_conns` (503 when full), `read_header_timeout`
- Optional `send_date` / `server_header` on responses
- Zero deps beyond V stdlib

**Bench (honest, local laptop, v0.5.0 `-prod`):** HTTP `GET /` sustains ~**60–85k req/s** (oha, 10s); short low-concurrency bursts ~**95k**. WebSocket echo ~**11–23k msg/s** (Python client, lower bound). See [benches/RESULTS.md](benches/RESULTS.md).

## Example

```v
module main
import viltrum

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.use(viltrum.cors('*'))
	app.mount('/api', fn (mut m viltrum.Mount) {
		m.get('/hi/:name', fn (req viltrum.Request) viltrum.Response {
			name := req.param('name') or { 'world' }
			return viltrum.json(200, '{"hi":"${name}"}')
		})
		m.get('/files/*path', fn (req viltrum.Request) viltrum.Response {
			return viltrum.text(200, req.param('path') or { '' })
		})
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

## WebSocket (`ws://`)

First-party RFC 6455 server on the same engine as HTTP — not a wrapper.

```v
app.ws('/ws', fn (mut s viltrum.WsSocket) {
	for {
		msg := s.read_message() or { break }
		if msg.is_text() {
			s.write_text(msg.text()) or { break }
		}
	}
	s.close_quiet()
})
```

Details: [docs/ws.md](./docs/ws.md). Demo: `examples/ws_echo` (`websocat ws://127.0.0.1:8084/ws`).

## Upgrade (hijack)

```v
app.upgrade('GET', '/echo', fn (mut c viltrum.Conn, req viltrum.Request) {
	c.write_all(viltrum.switching_protocols('echo').to_bytes()) or { return }
	mut buf := []u8{len: 4096}
	for {
		n := c.read(mut buf) or { break }
		if n == 0 { break }
		c.write_all(buf[..n]) or { break }
	}
	c.close() or {}
})
```

Details: [docs/upgrade.md](./docs/upgrade.md). Demo: `examples/upgrade_echo`.

## Examples

| Path | Port |
|------|------|
| `examples/hello` | 8080 |
| `examples/rest` | 8081 |
| `examples/features` | 8082 |
| `examples/upgrade_echo` | 8083 |
| `examples/ws_echo` | 8084 |

```bash
v test http/
v test router/
v test engine/
v test ws/
bash benches/run.sh
```

## Status

**v0.5.0** — first-party cleartext WebSocket (`ws://`) on the same Conn path as HTTP. Own engine end to end: TCP → HTTP/1.1 → Conn → WS frames. Reverse proxy for TLS is fine today; in-process TLS / `wss://` is v0.6.

**North star:** when people say Viltrum, they mean a first-party engine — performance and ergonomics both non-negotiable.

Full plan: **[ROADMAP.md](./ROADMAP.md)**.

### Non-goals (standing)

- HTTP/2, HTTP/3
- Application platform: sessions, auth providers, templates, ORM
- Edge TLS terminator / multi-tenant gateway
- Full RFC surface “for completeness”
- Trading DX for bench numbers

### Later

| Track | Status |
|-------|--------|
| WebSocket `ws://` | **done** (0.5) — [docs/ws.md](./docs/ws.md) |
| In-process TLS / `wss://` | planned 0.6 — [interest](https://github.com/Tuntii/viltrum/labels/interest%3Atls) |
| Reverse proxy + cleartext | **first-class forever** — [docs/deploy.md](./docs/deploy.md) |

### Docs

| Doc | Topic |
|-----|--------|
| [docs/connection.md](./docs/connection.md) | Accept → read → handler / upgrade → close |
| [docs/upgrade.md](./docs/upgrade.md) | Hijack contract, leftover ownership, 101 |
| [docs/ws.md](./docs/ws.md) | First-party WebSocket API + limits |
| [docs/deploy.md](./docs/deploy.md) | Caddy/nginx, Host, timeouts |
| [docs/request-response.md](./docs/request-response.md) | Request/Response, `ctx` |
| [ROADMAP.md](./ROADMAP.md) | Phases 0.3 → 0.7+ |

### Protocol notes

- Request bodies: **`Content-Length` only**. TE (chunked) → **400**; TE+CL → **400 conflict**.
- **HEAD:** body octets omitted on the wire; GET routes serve HEAD.
- **`Expect: 100-continue`:** minimal interim `100 Continue` when body still streaming.
- **Upgrade:** one API (`app.upgrade`); leftover bytes only via `Conn.read` pushback.

## License

MIT
