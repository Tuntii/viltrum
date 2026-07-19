<p align="center">
  <img src="assets/logo.svg" alt="Viltrum" width="160" height="160">
</p>

# Viltrum

HTTP framework for [V](https://vlang.io): own TCP accept loop, own HTTP/1.1 framing, own connection model, own WebSocket server. Small public API. No third-party deps.

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/Tuntii/viltrum)](https://github.com/Tuntii/viltrum/releases)

## Install

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh
v run examples/hello
```

`install.sh` links the repo at `~/.vmodules/viltrum`. Requires [V](https://github.com/vlang/v) on `PATH`.

More detail: [docs/getting-started.md](docs/getting-started.md).

## Quick start

Prefer a **selective import** so handlers stay short:

```v
module main

import viltrum {
	new
	recover
	text
	json
	Request
	Response
}

fn main() {
	mut app := new()
	app.use(recover)

	app.get('/', fn (req Request) Response {
		return text(200, 'ok\n')
	})

	app.get('/hi/:name', fn (req Request) Response {
		name := req.param('name') or { 'world' }
		return json(200, '{"hi":"${name}"}')
	})

	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

`import viltrum` alone works too (`viltrum.new()`, `viltrum.Request`, …). Docs use the selective form by default.

### WebSocket

Cleartext `ws://` on the same engine (RFC 6455). TLS at the reverse proxy until in-process TLS lands.

```v
import viltrum { new, WsSocket }

mut app := new()
app.ws('/ws', fn (mut s WsSocket) {
	for {
		msg := s.read_message() or { break }
		if msg.is_text() {
			s.write_text(msg.text()) or { break }
		}
	}
	s.close_quiet()
})
```

```bash
v run examples/ws_echo
# websocat ws://127.0.0.1:8084/ws
```

[docs/ws.md](docs/ws.md)

### Connection upgrade

```v
import viltrum { new, Conn, Request, switching_protocols }

mut app := new()
app.upgrade('GET', '/echo', fn (mut c Conn, req Request) {
	c.write_all(switching_protocols('echo').to_bytes()) or { return }
	// own the stream…
	c.close() or {}
})
```

[docs/upgrade.md](docs/upgrade.md)

## What is included

| Area | Notes |
|------|--------|
| HTTP/1.1 | Keep-alive, Host check, limits, graceful listener stop |
| Router | `:param`, trailing `*wildcard`, HEAD→GET |
| App | `mount`, `chain`, `cors`, `static_files`, `logger`, `recover` |
| Upgrade | `Conn` + `app.upgrade` |
| WebSocket | `app.ws` / `WsSocket` (`ws://`) |
| Bodies | `Content-Length` only (chunked / TE → 400) |

## Documentation

| Doc | Topic |
|-----|--------|
| [docs/README.md](docs/README.md) | Index |
| [docs/getting-started.md](docs/getting-started.md) | Install, import style, first server |
| [docs/request-response.md](docs/request-response.md) | Request, Response, middleware |
| [docs/connection.md](docs/connection.md) | Connection lifecycle |
| [docs/upgrade.md](docs/upgrade.md) | Hijack / leftover ownership |
| [docs/ws.md](docs/ws.md) | WebSocket API and limits |
| [docs/deploy.md](docs/deploy.md) | Proxy, Host, timeouts |
| [ROADMAP.md](ROADMAP.md) | Planned work |
| [docs/releasing.md](docs/releasing.md) | Semantic-release |

## Examples

| Path | Port |
|------|------|
| `examples/hello` | 8080 |
| `examples/rest` | 8081 |
| `examples/features` | 8082 |
| `examples/upgrade_echo` | 8083 |
| `examples/ws_echo` | 8084 |

## Performance

Local laptop, v0.5 `-prod`, honest runs (not a lab claim):

- HTTP `GET /`: roughly **60–85k req/s** sustained (oha, 10s)
- WebSocket echo: roughly **11–23k msg/s** (Python client, lower bound)

Method and raw notes: [benches/RESULTS.md](benches/RESULTS.md).

```bash
bash benches/run.sh
bash benches/run_ws.sh
```

## Status

Current release: **v0.5.x** — cleartext HTTP + first-party `ws://`. Reverse proxy for TLS is the supported edge path; in-process HTTPS/WSS is roadmap **0.6**.

Not planned: HTTP/2–3, sessions/ORM/templates, competing as a TLS terminator. Full list: [ROADMAP.md](ROADMAP.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Releases on `main` use [semantic-release](docs/releasing.md) from conventional commits (`feat:`, `fix:`, …).

## License

[MIT](LICENSE)
