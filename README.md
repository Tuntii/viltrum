<p align="center">
  <img src="assets/logo.svg" alt="Viltrum" width="140" height="140">
</p>

# Viltrum

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/Tuntii/viltrum)](https://github.com/Tuntii/viltrum/releases)

You write a few routes. Viltrum owns the rest of the wire: accept loop, HTTP/1.1, keep-alive, hijack, WebSocket frames. No third-party stack under the hood. No ORM, sessions, or template engine pretending to be a framework.

Built for [V](https://vlang.io). Cleartext first; put Caddy or nginx in front when you want edge TLS. Optional in-process HTTPS/WSS via `app.listen_tls` (mbedtls) for single-binary demos.

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh   # ~/.vmodules/viltrum → this tree
v run examples/hello
# curl http://127.0.0.1:8080/
```

Needs `v` on your `PATH`.

---

## A server in one file

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

Selective imports keep handlers short. Full prefixes (`import viltrum` + `viltrum.new()`) work if you prefer them.

### WebSocket without a second stack

Same process, same `Conn` model. Text and binary, ping/pong, size limits. Over TLS: same `app.ws` + `app.listen_tls` → `wss://` (see [docs/ws.md](docs/ws.md), [docs/tls.md](docs/tls.md)).

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
app.listen('127.0.0.1:8084') or { panic(err) }
```

```bash
v run examples/ws_echo
websocat ws://127.0.0.1:8084/ws

bash scripts/dev-cert.sh
v run examples/wss_echo
websocat -k wss://127.0.0.1:8444/ws
```

### When HTTP is not enough

```v
import viltrum { new, Conn, Request, switching_protocols }

app.upgrade('GET', '/echo', fn (mut c Conn, req Request) {
	c.write_all(switching_protocols('echo').to_bytes()) or { return }
	// you own the bytes after 101
	c.close() or {}
})
```

---

## What you actually get

| | |
|--|--|
| HTTP/1.1 | Keep-alive, Host check, body size limits, optional Date/Server |
| Router | `:param`, trailing `*wildcard`, HEAD falls back to GET |
| App | `mount`, `chain`, cors, static files, logger, recover |
| Bodies | `Content-Length` only. Chunked / TE → **400** (no desync games) |
| Upgrade | One path: `app.upgrade` + `Conn` |
| WebSocket | `app.ws` on that path (`ws://`) |

Nothing here pretends to replace your reverse proxy.

---

## Numbers (laptop, not a lab)

v0.5, `-prod`, developer machine (Ryzen 7 class). Re-run yourself.

| Workload | Rough result |
|----------|----------------|
| `GET /` sustained (oha, 10s, c=50) | ~60–85k req/s |
| WebSocket echo (Python client) | ~11–23k msg/s (client-bound; lower bound) |

```bash
bash benches/run.sh
bash benches/run_ws.sh
```

Method notes: [benches/RESULTS.md](benches/RESULTS.md).

---

## Docs and examples

| Read when | Doc |
|-----------|-----|
| First hour | [docs/getting-started.md](docs/getting-started.md) |
| Request shape / middleware | [docs/request-response.md](docs/request-response.md) |
| Accept → close | [docs/connection.md](docs/connection.md) |
| Hijack contract | [docs/upgrade.md](docs/upgrade.md) |
| WebSocket limits | [docs/ws.md](docs/ws.md) |
| Proxy deploy | [docs/deploy.md](docs/deploy.md) |
| Full index | [docs/README.md](docs/README.md) |

| Example | Port |
|---------|------|
| `examples/hello` | 8080 |
| `examples/rest` | 8081 |
| `examples/features` | 8082 |
| `examples/upgrade_echo` | 8083 |
| `examples/ws_echo` | 8084 |

```bash
v test http/ && v test router/ && v test engine/ && v test ws/
```

---

## Full-stack starter (separate repo)

Want API + UI + login + CRUD in one process? Use the teaching template:

**[Tuntii/full-stack-viltrum-template](https://github.com/Tuntii/full-stack-viltrum-template)**

```bash
git clone https://github.com/Tuntii/full-stack-viltrum-template.git
cd full-stack-viltrum-template
bash scripts/setup.sh   # links this Viltrum checkout or clones main
v run .
# http://127.0.0.1:8090/  ·  admin@example.com / changethis
```

Inspired by [full-stack-fastapi-template](https://github.com/fastapi/full-stack-fastapi-template) — **not a port** (no Postgres, Docker, or React toolchain). Engine stays here; the starter lives in its own repo so app code and framework releases stay decoupled.

---

## Roadmap, in one breath

**Shipped (0.7.8):** cleartext HTTP/1.1, first-party `ws://`, optional in-process HTTPS/WSS, measured hot-path work with honest benches. Full-stack teaching app: [full-stack-viltrum-template](https://github.com/Tuntii/full-stack-viltrum-template).

**Next:** demand-driven backlog only (drain timeout, ops hooks, optional runtime-level perf) — see [ROADMAP.md](ROADMAP.md).

Not on the menu: HTTP/2–3, auth/session platforms, ORM, “be Caddy.”

---

## Contribute

Setup and commit style: [CONTRIBUTING.md](CONTRIBUTING.md).  
Releases: conventional commits → [semantic-release](docs/releasing.md) on `main`.

### Where to start

| Path | Why |
|------|-----|
| [full-stack-viltrum-template](https://github.com/Tuntii/full-stack-viltrum-template) | End-to-end product shape (API + SPA) |
| [examples/hello](examples/hello/) | Minimal server |
| [examples/rest](examples/rest/) | JSON CRUD without a UI |
| Open issues | https://github.com/Tuntii/viltrum/issues |

Harder engine work (timeouts, buffer profiles, runtime I/O) lives in [ROADMAP.md](ROADMAP.md) backlog — start there only if you already know the code.

---

## License

[MIT](LICENSE)
