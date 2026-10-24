<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-white.svg">
    <img src="assets/logo.svg" alt="Viltrum" width="140" height="140">
  </picture>
</p>

# Viltrum

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/Tuntii/viltrum)](https://github.com/Tuntii/viltrum/releases)
[![HTTP Arena H/1.1](https://img.shields.io/endpoint?url=https://http-arena.com/badge/viltrum/h1.json)](https://http-arena.com/frameworks/viltrum/)
[![HTTP Arena WebSocket](https://img.shields.io/endpoint?url=https://http-arena.com/badge/viltrum/ws.json)](https://http-arena.com/frameworks/viltrum/)

You write routes. Viltrum owns the wire: its own HTTP/1.1 engine, one epoll worker per CPU, pipelining, and no
allocation per request inside the framework. No third-party stack under the hood.

Built for [V](https://vlang.io). HTTPS in-process on the same workers, or behind a proxy.

**Platforms.** Serving is Linux only: the engine is epoll, and off Linux `listen` and `serve` return an
error. CI runs the unit tests on Linux, macOS and Windows and builds the examples on all three, so handlers
can be written and tested (`app.handle_raw`) on any of them.

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh   # ~/.vmodules/viltrum → this tree
v run examples/hello
# curl http://127.0.0.1:8080/
```

---

## A server in one file

```v
module main

import viltrum

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'ok\n')
	})
	app.get('/hi/:name', fn (mut c viltrum.Ctx) {
		c.text(200, c.param('name') or { 'world' })
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

Handlers get a `Ctx`: request views (`path`, `param`, `query_param`, `header`, `body`) and a response writer
(`text`, `text_int`, `json`, `bytes`, `no_content`, `set_header`). Request strings point into the connection's
buffer and are valid until the handler returns; `.clone()` what you keep.

---

## What you actually get

| Area | In 1.0 |
|------|--------|
| HTTP/1.1 | keep-alive, pipelining (responses batched into one write), `Expect: 100-continue`, HEAD |
| Bodies | `Content-Length` or `chunked`. Other codings, TE+CL, duplicate or non-digit CL, `Name :`, obs-fold, bare CR/LF → **400** (parser fuzzed in CI) |
| Engine | one `SO_REUSEPORT` epoll worker per CPU (cpuset-aware), backpressure, read/idle/write timeouts, `max_conns`, graceful SIGINT/SIGTERM |
| Routing | `:param`, trailing `*rest`, groups, global and per-route middleware (`c.next()`) |
| Middleware | `recover`, `gzip`, `cors`, `logger` (`recover` cannot catch panics, see below) |
| JSON | `c.json(200, value)`: compile-time encoder, no reflection |
| TLS | `app.listen_tls`, or `app.serve` for cleartext and TLS together: TLS 1.3, certificates reloaded from disk without a restart ([docs/tls.md](docs/tls.md)) |
| Static files | `app.static_files('/assets', './public')`, `c.file(path)`: ETag, Last-Modified, 304, byte ranges, large files sent with `sendfile` ([docs/files.md](docs/files.md)) |
| Forms | `c.form_value`, `c.form_file`, `c.form_parts`: urlencoded and multipart bodies parsed in place, no allocation ([docs/forms.md](docs/forms.md)) |
| WebSocket | `app.ws(pattern, handler)`: RFC 6455 on the same workers, `ws://` and `wss://`, callbacks per message with no allocation, topics (`subscribe` / `publish`) across workers ([docs/ws.md](docs/ws.md)) |
| Tests | `app.handle_raw(raw)` serves a raw request in-process |

> **`recover` and panics.** V cannot catch panics: a panic exits the process. `recover` only turns a handler that wrote no response into 500 and closes the connection. Run the server under a supervisor (e.g. systemd `Restart=always`).

Not on the 1.x core yet (they return later): the HTTP client, serving off Linux.

---

## Numbers

### HttpArena: first on HTTP/1.1 and on WebSocket

[HttpArena](https://http-arena.com) runs every entry on the same 64-thread machine with the same load generator.
In the 2026-10-23 results Viltrum is **first of 13 on HTTP/1.1** (composite 7786) and **first of 11 on
WebSocket** (composite 3000) in its category, with nine gold medals and one silver. The medals with their
results:

| | Profile | Connections | Result | Place |
|:-:|---------|------------:|-------:|------:|
| 🥇 | Baseline | 4,096 | 4.06M req/s | 1 / 13 |
| 🥇 | Short-lived connections | 4,096 | 2.70M req/s | 1 / 13 |
| 🥇 | JSON, gzip | 4,096 | 899K req/s | 1 / 12 |
| 🥇 | JSON over TLS | 4,096 | 1.61M req/s | 1 / 12 |
| 🥈 | Async (`/delay`) | 32,000 | 2.49M req/s | 2 / 11 |
| 🥇 | WebSocket echo | 512 | 4.27M msg/s | 1 / 11 |
| 🥇 | WebSocket echo, pipelined | 512 | 62.5M msg/s | 1 / 11 |
| 🥇 | WebSocket echo, short-lived | 512 | 2.22M msg/s | 1 / 11 |

The other medals, every profile and every connection count are on
[http-arena.com/frameworks/viltrum](https://http-arena.com/frameworks/viltrum/).

The category is **Experimental**: HttpArena's label for young frameworks without much production use yet. Its
default leaderboard shows flagship and emerging entries; tick Experimental to see Viltrum there. All three are
scored the same way, and the default view's leader has a composite of 7306.

Two weeks earlier (2026-10-14, v0.13.0) the same benchmark had Viltrum mid-pack: baseline 595K req/s, 99th of
151, and gzip JSON 14K req/s, 123rd of 125. What changed since is in the [release notes](https://github.com/Tuntii/viltrum/releases)
and [ROADMAP.md](ROADMAP.md). The entry lives in [benches/httparena](benches/httparena); method notes are in
[benches/RESULTS.md](benches/RESULTS.md).

---

## Docs and examples

| Read when | Doc |
|-----------|-----|
| First hour | [docs/getting-started.md](docs/getting-started.md) |
| Request shape / middleware | [docs/request-response.md](docs/request-response.md) |
| Accept → close | [docs/connection.md](docs/connection.md) |
| HTTPS | [docs/tls.md](docs/tls.md) |
| WebSocket | [docs/ws.md](docs/ws.md) |
| Proxy deploy | [docs/deploy.md](docs/deploy.md) |
| Full index | [docs/README.md](docs/README.md) |

| Example | Port |
|---------|------|
| `examples/hello` | 8080 |
| `examples/rest` | 8081 |
| `examples/features` | 8082 |
| `examples/https` | 8080 + 8443 (`bash scripts/dev-cert.sh` first) |
| `examples/ws_chat` | 8084 |

```bash
v test http1/ jsonenc/ router/ engine/ tests/
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

**1.0:** the zero-allocation core above (design: [docs/superpowers/specs/2026-10-15-v1-zero-alloc-core-design.md](docs/superpowers/specs/2026-10-15-v1-zero-alloc-core-design.md)).

**1.2:** TLS on the same workers ([docs/tls.md](docs/tls.md)).

**1.3:** WebSocket on the same workers ([docs/ws.md](docs/ws.md)).

**Next:** the rest of the 1.0 review backlog, the HTTP client ([ROADMAP.md](ROADMAP.md)).

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
