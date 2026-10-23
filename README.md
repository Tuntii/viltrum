<p align="center">
  <img src="assets/logo.svg" alt="Viltrum" width="140" height="140">
</p>

# Viltrum

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/Tuntii/viltrum)](https://github.com/Tuntii/viltrum/releases)
[![HTTP Arena H/1.1](https://img.shields.io/endpoint?url=https://http-arena.com/badge/viltrum/h1.json)](https://http-arena.com/#type=experimental&tuned=0)

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
| WebSocket | `app.ws(pattern, handler)`: RFC 6455 on the same workers, `ws://` and `wss://`, callbacks per message with no allocation, topics (`subscribe` / `publish`) across workers ([docs/ws.md](docs/ws.md)) |
| Tests | `app.handle_raw(raw)` serves a raw request in-process |

> **`recover` and panics.** V cannot catch panics: a panic exits the process. `recover` only turns a handler that wrote no response into 500 and closes the connection. Run the server under a supervisor (e.g. systemd `Restart=always`).

Not on the 1.x core yet (they return later): forms and uploads, the HTTP client, serving off Linux.

---

## Numbers (laptop, not a lab)

v0.12.1, `-prod`, this developer machine (Ryzen 7 4800H). Three-run median, 2026-09-25. Re-run yourself.

| Workload | Rough result |
|----------|----------------|
| `GET /` sustained (oha, 10s, c=50) | ~217k req/s (Axum peer ~221k on the same run) |
| `GET /` sustained (oha, 10s, c=100) | ~194k req/s (Axum peer ~247k) |
| WebSocket echo (Python client) | ~11–23k msg/s (2026-07-23, client-bound; not re-run) |

### HttpArena (shared 64-thread box, 2026-10-14, v0.13.0, `epoll_cores` entry)

The independent run, next to everything else on the same machine. Viltrum is mid-pack on plain HTTP and
WebSocket, and far behind on compressed JSON (fixed in v0.13.1: gzip ~3.5× faster locally, not yet re-run there).

| Profile | viltrum | Rank | Field median | Axum |
|---------|--------:|-----:|-------------:|-----:|
| baseline, 4096 conns | 595k | 99 / 151 | 1.16M | 1.08M |
| pipelined, 4096 conns | 981k | 98 / 140 | 2.49M | 6.48M |
| limited-conn, 4096 conns | 524k | 79 / 151 | 565k | 685k |
| json-comp, 4096 conns | 14k | 123 / 125 | 195k | 268k |
| echo-ws, 4096 conns | 2.13M | 32 / 55 | 2.29M | — |

It used 11–23 of the 64 cores on the HTTP profiles; GC pauses under many threads are the likely limit. Earlier
single-VM runs ([PIPELINE.md](benches/compare/PIPELINE.md)) showed viltrum ahead of Axum, which did not hold
on modern hardware. The entry lives in [benches/httparena](benches/httparena).

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

**Next:** hardening, forms and uploads on the new core ([ROADMAP.md](ROADMAP.md)).

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
