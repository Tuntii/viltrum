# Viltrum Roadmap

Last updated: 2026-10-27 · current release: **v1.13.1**

Viltrum is a small HTTP framework for [V](https://vlang.io) with its **own** HTTP/1.1 engine: one `SO_REUSEPORT`
epoll worker per CPU, pipelining, and no allocation per request inside the framework. Not a thin wrapper.

This document is the product plan. Phases are ordered, not calendar promises. Ship when green; skip vanity
milestones.

---

## North star

**When someone says “Viltrum,” they mean a first-party engine stack:** own accept loop, own HTTP/1.1, own
connection model, own WebSocket framing, own TLS integration — not a wrapper around another framework’s runtime.

Success looks like:

- Clone → `bash scripts/install.sh` → `v run examples/*` in minutes
- One mental model from Hello World → middleware → TLS → WebSocket
- Predictable connection lifecycle (keep-alive, timeouts, limits, graceful stop)
- Measured performance on independent benches, with the method written down
- Docs that state what we will **not** do as clearly as what we do

---

## Principles

1. **Small surface** — every public symbol must earn its place.
2. **Own engine, end to end** — accept loop, HTTP framing, connections, WS frames and the TLS integration stay
   first-party. Crypto comes from the TLS library V ships (mbedtls), except where it was the cost: the TLS 1.3
   records (AES-GCM) and the common TLS 1.3 handshake (X25519, RSA-PSS signing) are viltrum's own, held to
   the RFC vectors and to mbedtls in tests. No foreign server runtime underneath.
3. **Zero allocation on the hot path** — enforced by a test in CI. New features keep the gate green or say why not.
4. **Performance without DX sacrifice** — the public happy path stays short (`new` → routes → `listen`).
5. **Honest status** — benches with the method noted; “production” only with evidence.
6. **Proxy-friendly first** — a reverse proxy remains valid forever; in-process TLS is additive.
7. **Security before checkboxes** — TLS and WSS land only with tests, limits and clear failure modes.
8. **YAGNI between phases** — do not start N+1 while N is half-done.

---

## Where 1.x stands

| Area | Status |
|------|--------|
| HTTP/1.1 engine: epoll worker per CPU, pipelining, backpressure, timeouts, `max_conns`, graceful stop | done (1.0) |
| Zero-allocation request path, enforced in CI; parser fuzzed in CI | done (1.0) |
| Router (`:param`, `*rest`, groups), middleware chain, `recover` / `gzip` / `cors` / `logger` | done (1.0) |
| Compile-time JSON encoder | done (1.0) |
| Closed connections pooled per worker | done (1.0.3) |
| Buffers lent per event from worker pools: a quiet connection holds none, TLS included | done (Phase 8) |
| Deferred responses (`c.after`) from per-worker timers, nanosecond waits | done (1.1.0, 1.5.1) |
| TLS on the same workers, certificate reload | done (1.2.0) |
| Own TLS 1.3 handshake for X25519 + RSA certificates, mbedtls for the rest ([design](docs/design/1.x-tls-handshake.md)) | done (1.7.0) |
| gzip on viltrum's own DEFLATE encoder | done (1.2.2) |
| WebSocket (`ws://`, `wss://`) | done (Phase 3) |
| Static files (`static_files`, `c.file`): validators, ranges, `sendfile` | done (Phase 4) |
| Forms and uploads (`form_value`, `form_file`, `form_parts`) | done (Phase 4) |
| Streaming responses and Server-Sent Events (`c.stream`, `c.sse`), HTTP/1.1 and HTTP/2 | done (Phase 7) |
| Generic upgrade, HTTP client | **not on the 1.0 core yet** (they existed on 0.x) |

Independent results: the [HttpArena](https://www.http-arena.com) entry lives in
[benches/httparena](benches/httparena). In the 2026-10-26 results (v1.10.0) viltrum is first of 19 on HTTP/1.1
(composite 7936), first of 14 on WebSocket and second of 10 on HTTP/2 in the Experimental category, with eleven
gold medals: the HTTP/1.1 and WebSocket composites, async, short-lived connections, json-comp, json-tls,
baseline-h2, baseline-h2c and the three echo-ws profiles. Silver on the HTTP/2 composite and json-h2c, bronze on
baseline and latency at 1M req/s.
[HttpArena#1660](https://github.com/MDA2AV/HttpArena/pull/1660) moves the entry to v1.13.1 (buffers lent per
event, Phase 8) and waits for a benchmark run. The
[the-benchmarker](https://github.com/the-benchmarker/web-frameworks) entry (v1.3.2) is merged and waits for
their next run.

---

## Phase 1 — TLS on the 1.0 core

**Goal:** `https://` on the same epoll workers as cleartext, with no allocation added per request.

- [x] Design doc: mbedtls in non-blocking mode inside the epoll loop (handshake state, `WANT_READ` /
      `WANT_WRITE` mapped to epoll interest, partial writes, `close_notify` on close)
- [x] Several listeners in one process (cleartext and TLS side by side), e.g. `app.listen_tls(addr, TlsOptions)`
- [x] Policy: TLS 1.3 preferred, TLS 1.2 minimum, AEAD ciphers only, ALPN `http/1.1`, works without SNI
- [x] Certificate reload without a restart: `stat` the files at most once a second on handshake, reload on
      change, keep the last good pair when the new one fails to load (half-swapped files)
- [x] Check that AES-NI is used by the mbedtls build; measure TLS against cleartext
- [x] Tests: handshake, pipelining over TLS, partial writes, `close_notify`, reload, rejected old protocols,
      zero-alloc gate on the TLS path
- [x] CI, `docs/tls.md` for 1.x, README status
- [x] Release (minor): v1.2.0
- [x] HttpArena: `json-tls` and `8gbit` (`POST /echo`, 10–100 KB bodies including chunked), `tls_check`

## Phase 2 — Compressed JSON throughput

**Goal:** close most of the json-comp gap without leaving the framework's gzip middleware.

- [x] Profile json-comp on Linux: share of time in gzip vs the JSON encoder
- [x] Faster deflate path: viltrum's own DEFLATE encoder in place of miniz, and in-place JSON writes
- [x] Re-measure, release: v1.2.1, v1.2.2 (+59% json-comp throughput on the bench box)

## Phase 3 — WebSocket on the 1.0 core

- [x] Upgrade on the epoll worker: `app.ws` with middleware on the upgrade request (generic hijack stays
      out until something needs it)
- [x] RFC 6455 frames, non-blocking, with limits; WSS on top of Phase 1; zero-alloc gate on the echo path
- [x] HttpArena echo-ws profiles

## Phase 4 — 1.0 hardening and the missing pieces

- [x] The known gaps below that matter in production first: lingering close, 413 at the read cap and for
  any oversized `Content-Length`, EINTR on recv/send
- [x] Static files back on the new core: `app.static_files`, `c.file`, ETag / Last-Modified / 304, byte
  ranges, large files streamed with `sendfile` ([docs/files.md](docs/files.md))
- [x] Forms and uploads back on the new core: `c.form_value`, `c.form_file`, `c.form_parts`, parsed in place
  ([docs/forms.md](docs/forms.md))

## Phase 5 — HTTP/2

Decided on 2026-10-24: cleartext h2 first, then h2 over TLS via ALPN. Design:
[docs/design/1.x-http2.md](docs/design/1.x-http2.md).

- [x] HPACK (RFC 7541) in `viltrum.http2`, held to the RFC's examples and fuzzed
- [x] h2c: prior knowledge on a cleartext listener beside HTTP/1.1, requests through the same router,
      middleware and `Ctx`; flow control and the limits HTTP/2 needs (stream count, CONTINUATION, resets);
      h2spec 144/146 ([docs/http2.md](docs/http2.md))
- [x] `c.after` (deferred responses) over HTTP/2: a timer per stream, only that stream waits
- [x] h2 over TLS, chosen by ALPN, on both handshake paths (mbedtls and our own); h2spec 145/146
- [x] HttpArena's HTTP/2 profiles: baseline-h2, static-h2, baseline-h2c, json-h2c (2026-10-26: gold on
      baseline-h2 and baseline-h2c, second on the HTTP/2 composite)

## Phase 6 — Community

- [x] Examples and the [full-stack starter](https://github.com/Tuntii/full-stack-viltrum-template) on 1.x
- [x] Write-ups of the engine design and the benchmark method, on tuntii.com:
      [the 1.x engine](https://tuntii.com/blog/viltrum-1x-motoru-cope-atip-yeniden-yazmak/),
      [the HttpArena method](https://tuntii.com/blog/viltrum-httparena-benchmark-yontemi/) (Turkish)
- [ ] Answer issues quickly; credit outside contributions in release notes

## Phase 7 — Streaming responses and Server-Sent Events

Decided on 2026-10-25: streaming first; the other candidates wait in the feature backlog below. Design:
[docs/design/1.x-streaming.md](docs/design/1.x-streaming.md).

- [x] 7a, HTTP/1.1: `c.stream` / `c.sse` with a `StreamHandler`. Covers writes, `end`, timers on the stream,
      `on_drain` for bodies generated at the client's pace, SSE framing and heartbeat, and sends and topic
      publishes from any thread through the hub. Zero-allocation gate on the stream path
      ([docs/streaming.md](docs/streaming.md))
- [x] 7b, HTTP/2: the same API per HTTP/2 stream, many streams on one connection, within flow control;
      RST_STREAM ends a stream, a slow stream is reset alone. Zero-allocation gate on the HTTP/2 stream path

## Phase 8 — Memory per connection

Decided on 2026-10-26, after HttpArena's memory-efficiency view put viltrum second: every connection held an
8 KiB read and a 16 KiB write buffer for its life (about 33 KiB with the GC's share), and a TLS one about 100 KiB.

- [x] Buffers lent from per-worker pools while there is something in them, taken back when an event leaves
      them empty; zero-allocation gate on the lend/settle cycle
- [x] TLS: tls13's record buffers and the handshake's read-ahead lent the same way; mbedtls' context set up
      only for sessions mbedtls has
- [x] HTTP/2: measured on 2026-10-31, the tables and stream slots are small (two slots, no held output, at close);
      the 875 MiB static-h2 took at 1024 connections on v1.10.0 was the buffers, and the v1.13.1 run shows 237 MiB
- [x] `static_files` keeps small files in memory per worker, revalidated by one `stat` per request: 6.4 syscalls a
      static-h2 request down to 2.1, 45% less system time over h2c (static-h2 spent 163 us CPU a request against
      39-66 for the leaders)

## Feature backlog

Candidates for the phases after 7, in no order; each needs its own decision before it starts.

| Feature | What it takes, and why |
|---------|------------------------|
| Async HTTP client | Non-blocking requests from handlers, on the same epoll workers, with keep-alive pooling and TLS. Unblocks Sharkbench, reverse proxying and upstream calls; existed on 0.x |
| WebSocket over HTTP/2 | RFC 8441 (extended CONNECT) and permessage-deflate. Today an upgrade over HTTP/2 answers 501 |
| Observability | `/metrics` in the Prometheus format (requests, latency histogram, connections), request IDs, structured access logs |

---

## 1.0 core — known gaps (backlog from the 1.0 review)

None are smuggling or correctness bugs on valid traffic; pull when touched or asked.

| Area | Gap |
|------|-----|
| Router | 404/405 cost O(routes) |
| API | `Ctx` exposes internals as `pub mut` (`buf`, `out`, `chain`, `idx`, …); request counter not on `App` |
| Tests | EMFILE path |
| Lint | Map/array literals not linted (the zero-alloc gate is the real enforcement) |

---

## Non-goals (standing)

Unless this file is explicitly revised:

- Competing as edge TLS terminator / multi-tenant gateway (no ACME inside viltrum)
- Application platform: sessions, auth providers, template engine, ORM
- Wrapping another language’s framework
- Implementing full RFC surface “for completeness”

---

## History

The 0.x line (2026-07 to 2026-10) built the first engine: spawn-per-connection accept, HTTP/1.1, hijack /
upgrade, WebSocket, in-process TLS on mbedtls with SIGHUP reload, forms, a minimal client, and the hot-path
work that ended in v0.13. 1.0 replaced that engine with the zero-allocation epoll core and dropped what had
not been ported yet. Details per release: [CHANGELOG.md](CHANGELOG.md); the 0.x roadmap is in git history.
