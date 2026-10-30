<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-white.svg">
    <img src="assets/logo.svg" alt="Viltrum" width="140" height="140">
  </picture>
</p>

<h1 align="center">Viltrum</h1>

<p align="center">
  <strong>A web framework for V that owns the wire.</strong><br>
  Its own HTTP/1.1, HTTP/2, WebSocket and TLS 1.3 engine. One epoll worker per CPU. No allocation per request.
</p>

<p align="center">
  <a href="https://github.com/Tuntii/viltrum/actions/workflows/ci.yml"><img src="https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <a href="https://github.com/Tuntii/viltrum/releases"><img src="https://img.shields.io/github/v/release/Tuntii/viltrum" alt="release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Tuntii/viltrum" alt="MIT license"></a>
  <a href="https://http-arena.com/frameworks/viltrum/"><img src="https://img.shields.io/endpoint?url=https://http-arena.com/badge/viltrum/h1.json" alt="HttpArena HTTP/1.1"></a>
  <a href="https://http-arena.com/frameworks/viltrum/"><img src="https://img.shields.io/endpoint?url=https://http-arena.com/badge/viltrum/h2.json" alt="HttpArena HTTP/2"></a>
  <a href="https://http-arena.com/frameworks/viltrum/"><img src="https://img.shields.io/endpoint?url=https://http-arena.com/badge/viltrum/ws.json" alt="HttpArena WebSocket"></a>
</p>

<p align="center">
  <a href="https://github.com/Tuntii/viltrum/wiki">Documentation</a> ·
  <a href="examples/README.md">Examples</a> ·
  <a href="#benchmarks">Benchmarks</a> ·
  <a href="https://github.com/users/Tuntii/projects/3">Roadmap</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="https://v.rustapi.cloud">Live demo</a>
</p>

---

**First of 19 on HTTP/1.1 and first of 14 on WebSocket** in [HttpArena](https://http-arena.com/frameworks/viltrum/)'s
Experimental category, with eleven gold medals. On 2026-10-14, twelve days before that run, the same benchmark had
Viltrum 99th of 151 on its baseline. Everything between the two is in this repository: a new engine, its own TLS 1.3 records and
handshake, its own DEFLATE encoder, HTTP/2, and a CI gate that fails if a request allocates a single byte.

## Quick start

```bash
v install --git https://github.com/Tuntii/viltrum
```

```v
module main

import tuntii.viltrum

struct Hello {
	message string
	name    string
}

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'ok\n')
	})
	app.get('/hi/:name', fn (mut c viltrum.Ctx) {
		c.json(200, Hello{
			message: 'hello'
			name:    c.param('name') or { 'world' }
		})
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

```console
$ v run . &
$ curl localhost:8080/hi/ada
{"message":"hello","name":"ada"}
```

Requires [V](https://vlang.io) 0.5.2 or V master; CI builds and tests on both. Serving needs Linux (the engine is
epoll). On macOS and Windows the framework builds and its unit tests run, so handlers can be written and tested
there with `app.handle_raw`.

Working on Viltrum itself? Clone it and link the checkout as `import viltrum`:

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh      # ~/.vmodules/viltrum -> this tree
v run examples/hello
```

## Why Viltrum

**The engine is the framework.** The accept loop, the HTTP/1.1 parser, HTTP/2 with HPACK, WebSocket framing, the
TLS 1.3 record layer and the common TLS 1.3 handshake (X25519, RSA-PSS) are written here, not wrapped. The rest of
the crypto comes from mbedtls, which ships with V. `v.mod` lists no dependencies.

**No allocation per request, enforced.** Tests run each request shape 10,000 times and fail if the GC heap grows by
one byte, on HTTP/1.1, HTTP/2, TLS, WebSocket, streaming, static files and deferred responses. Request strings are
views into the connection's buffer; `.clone()` what you keep past the handler.

**One model for every protocol.** The same router, middleware chain and `Ctx` answer HTTP/1.1, HTTP/2 over TLS and
cleartext h2c on the same port. WebSocket upgrades go through the same middleware. Streaming and Server-Sent Events
work over HTTP/1.1 and HTTP/2.

**Held to the specs.** The network parsers are fuzzed in CI, 500,000 mutations each: HTTP/1.1, HPACK, HTTP/2
frames, WebSocket frames and the TLS handshake. [h2spec](docs/http2.md#how-it-is-checked) passes 145
of 146 over TLS. [Autobahn|Testsuite](benches/AUTOBAHN.md) reports no failures in any section Viltrum implements.

## What you get

| Area | |
|------|---|
| HTTP/1.1 | keep-alive, pipelining (responses batched into one write), `Expect: 100-continue`, HEAD. Ambiguous framing (TE+CL, duplicate or non-digit CL, obs-fold, bare CR/LF) answers **400** |
| Engine | one `SO_REUSEPORT` epoll worker per CPU (cpuset-aware), backpressure, read/idle/write timeouts, `max_conns`, buffers lent per event so an idle connection holds none, graceful SIGINT/SIGTERM |
| Routing | `:param`, trailing `*rest`, groups, global and per-route middleware (`c.next()`) |
| Middleware | `recover`, `gzip` (on Viltrum's own DEFLATE encoder), `cors`, `logger` |
| JSON | `c.json(200, value)`: encoder generated per type at compile time, no reflection |
| TLS | `app.listen_tls`, or `app.serve` for cleartext and TLS listeners together: TLS 1.3, certificates reloaded from disk without a restart ([TLS](docs/tls.md)) |
| HTTP/2 | `Listener{ addr, http2: true }`: over TLS (ALPN) and cleartext h2c, beside HTTP/1.1 on the same port; flow control and the RFC 9113 limits ([HTTP/2](docs/http2.md)) |
| WebSocket | `app.ws(pattern, handler)`: RFC 6455, `ws://` and `wss://`, topics with `subscribe` / `publish` across workers ([WebSocket](docs/ws.md)) |
| Streaming and SSE | `c.stream`, `c.sse`: bodies written from timers, from any thread, or as the client reads them (`on_drain`); many streams per HTTP/2 connection ([Streaming](docs/streaming.md)) |
| Static files | `app.static_files`, `c.file`: ETag, Last-Modified, 304, byte ranges, precompressed `.br`/`.gz`, `sendfile` ([Static files](docs/files.md)) |
| Forms | `c.form_value`, `c.form_file`, `c.form_parts`: urlencoded and multipart, parsed in place ([Forms](docs/forms.md)) |
| Deferred responses | `c.after(ms, cb, arg)`: answer later from a per-worker timer without holding a thread |
| Testing | `app.handle_raw(raw)` serves a raw request in-process |

> **Panics.** V cannot catch a panic: it exits the process. `recover` turns a handler that wrote nothing into a 500
> and closes the connection. Run the server under a supervisor such as systemd with `Restart=always`.

Not on the 1.x core yet: an HTTP client, and serving off Linux.

## Benchmarks

[HttpArena](https://http-arena.com) runs every entry on the same machine (AMD Threadripper PRO 3995WX, 64 cores)
with the same load generator. Results of the v1.10.0 run, as shown on
[http-arena.com/frameworks/viltrum](https://http-arena.com/frameworks/viltrum/) on 2026-10-30:

| | Profile | Connections | Result | Place |
|:-:|---------|------------:|-------:|------:|
| 🥇 | HTTP/1.1 composite | | 7936 | 1 / 19 |
| 🥇 | WebSocket composite | | | 1 / 14 |
| 🥇 | Async (`/delay`) | 32,000 | 2.83M req/s | 1 / 17 |
| 🥇 | Short-lived connections | 4,096 | 2.74M req/s | 1 / 19 |
| 🥇 | JSON, gzip | 4,096 | 959K req/s | 1 / 18 |
| 🥇 | JSON over TLS | 4,096 | 1.82M req/s | 1 / 18 |
| 🥇 | HTTP/2 baseline, over TLS | 256 | 14.6M req/s | 1 / 9 |
| 🥇 | HTTP/2 baseline, cleartext (h2c) | 256 | 14.5M req/s | 1 / 10 |
| 🥇 | WebSocket echo | 512 | 4.27M msg/s | 1 / 14 |
| 🥇 | WebSocket echo, pipelined | 512 | 63.1M msg/s | 1 / 14 |
| 🥇 | WebSocket echo, short-lived | 512 | 2.24M msg/s | 1 / 14 |
| 🥈 | HTTP/2 composite | | | 2 / 10 |
| 🥈 | JSON over h2c | 1,024 | 4.74M req/s | 2 / 10 |
| 🥉 | Baseline | 4,096 | 4.08M req/s | 3 / 19 |
| 🥉 | Latency at 1M req/s | 1,024 | p99 164 µs | 3 / 17 |

Places average every connection count a profile runs, not only the one shown. Latency profiles are scored on CPU
per request and latency at a fixed rate, and JSON, gzip on throughput and bytes per response together, so their
places do not follow the req/s order.

**Experimental** is HttpArena's category for young frameworks without much production use yet; its default
leaderboard shows flagship and emerging entries, so tick Experimental to see Viltrum there. The entry's source is
[benches/httparena](benches/httparena), and the method notes are in [benches/RESULTS.md](benches/RESULTS.md).
Viltrum is also entered in [the-benchmarker/web-frameworks](https://github.com/the-benchmarker/web-frameworks).

## Examples

| Example | Shows |
|---------|-------|
| [hello](examples/hello) | text responses and a `:param` |
| [rest](examples/rest) | JSON in and out, shared state behind a mutex |
| [features](examples/features) | middleware, groups, query params, gzip, static files, a file upload |
| [https](examples/https) | cleartext and HTTPS listeners on the same workers |
| [ws_chat](examples/ws_chat) | WebSocket rooms, `subscribe` / `publish` across workers |
| [sse](examples/sse) | Server-Sent Events: a timer clock, a chat topic, a CSV generated at the client's pace |

Ports and `curl` lines for each are in [examples/README.md](examples/README.md).

For a whole application (API, UI, login, CRUD in one process), start from
**[full-stack-viltrum-template](https://github.com/Tuntii/full-stack-viltrum-template)**. It runs the
[live demo](https://v.rustapi.cloud).

## Documentation

The guides live in [`docs/`](docs/README.md) and are mirrored to the [wiki](https://github.com/Tuntii/viltrum/wiki).

| Read when | Guide |
|-----------|-------|
| Your first hour | [Getting started](docs/getting-started.md) |
| Writing handlers and middleware | [Request and response](docs/request-response.md) |
| Tuning workers, limits and timeouts | [Connections](docs/connection.md) |
| Serving HTTPS or HTTP/2 | [TLS](docs/tls.md), [HTTP/2](docs/http2.md) |
| Real-time features | [WebSocket](docs/ws.md), [Streaming and SSE](docs/streaming.md) |
| Going to production | [Deploy](docs/deploy.md) |

Design notes for the larger pieces: [TLS](docs/design/1.x-tls.md),
[the TLS 1.3 handshake](docs/design/1.x-tls-handshake.md), [HTTP/2](docs/design/1.x-http2.md),
[streaming](docs/design/1.x-streaming.md).

## Roadmap

Open work is on the [project board](https://github.com/users/Tuntii/projects/3): the HTTP/2 share of the
per-connection memory work, an async HTTP client, WebSocket over HTTP/2, and metrics. Each feature gets its own
decision before it starts; the plan, its principles and what Viltrum will not do are in [ROADMAP.md](ROADMAP.md).

## Contributing

Bug reports, questions and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the checks
CI runs and the commit style; releases are cut by [semantic-release](docs/releasing.md) from conventional commits
on `main`. Cards on the [project board](https://github.com/users/Tuntii/projects/3) marked *Known gaps* are small,
self-contained places to start.

Found a security problem? Report it privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

[MIT](LICENSE)
