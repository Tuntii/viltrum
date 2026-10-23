# Viltrum Roadmap

Last updated: 2026-10-22 · current release: **v1.2.2**

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
   first-party. Crypto comes from the TLS library V ships (mbedtls); no foreign server runtime underneath.
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
| Deferred responses (`c.after`) from per-worker timers | done (1.1.0) |
| TLS on the same workers, certificate reload | done (1.2.0) |
| gzip on viltrum's own DEFLATE encoder | done (1.2.2) |
| WebSocket (`ws://`, `wss://`) | done (Phase 3) |
| Static files (`static_files`, `c.file`): validators, ranges, `sendfile` | done (Phase 4) |
| Generic upgrade, forms and uploads, HTTP client | **not on the 1.0 core yet** (they existed on 0.x) |

Independent results: the [HttpArena](https://www.http-arena.com) entry lives in
[benches/httparena](benches/httparena). On the 2026-10-20 run viltrum was near the top on baseline,
limited-conn, async and the latency profiles, mid-field on json-comp, and absent from every TLS profile.

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
- [ ] HttpArena: `json-tls` and `8gbit` (`POST /echo`, 10–100 KB bodies including chunked), `tls_check`
      (entry validated, waiting for the benchmark run)

## Phase 2 — Compressed JSON throughput

**Goal:** close most of the json-comp gap without leaving the framework's gzip middleware.

- [x] Profile json-comp on Linux: share of time in gzip vs the JSON encoder
- [x] Faster deflate path: viltrum's own DEFLATE encoder in place of miniz, and in-place JSON writes
- [x] Re-measure, release: v1.2.1, v1.2.2 (+59% json-comp throughput on the bench box)

## Phase 3 — WebSocket on the 1.0 core

- [x] Upgrade on the epoll worker: `app.ws` with middleware on the upgrade request (generic hijack stays
      out until something needs it)
- [x] RFC 6455 frames, non-blocking, with limits; WSS on top of Phase 1; zero-alloc gate on the echo path
- [ ] HttpArena echo-ws profiles (entry validated)

## Phase 4 — 1.0 hardening and the missing pieces

- [ ] The known gaps below that matter in production first (lingering close, 413 at the read cap, EINTR)
- [x] Static files back on the new core: `app.static_files`, `c.file`, ETag / Last-Modified / 304, byte
  ranges, large files streamed with `sendfile` ([docs/files.md](docs/files.md))
- [ ] Forms and uploads back on the new core

## Phase 5 — HTTP/2 (decision needed)

Not planned today. Revisit after Phases 1–3: cleartext h2 first, then h2 over TLS via ALPN.

## Phase 6 — Community

- [ ] Examples and the [full-stack starter](https://github.com/Tuntii/full-stack-viltrum-template) on 1.x
- [ ] Write-ups of the engine design and the benchmark method
- [ ] Answer issues quickly; credit outside contributions in release notes

---

## 1.0 core — known gaps (backlog from the 1.0 review)

None are smuggling or correctness bugs on valid traffic; pull when touched or asked.

| Area | Gap |
|------|-----|
| Engine | No lingering close (a client still uploading may get RST instead of the 413/400); land with uploads |
| Engine | rbuf full at the cap closes silently instead of 413 (only via chunk overhead); EINTR on recv/send closes |
| Engine | `epoll_ctl(DEL)` result unchecked; listener leak on startup failure; port 0 binds a different port per worker |
| Engine | `is_http10` misses a request with a leading bare CRLF (may send 100 Continue to HTTP/1.0) |
| HTTP | No `Allow` header on 405; 10-digit Content-Length > i32 answers 400 instead of 413 |
| Router | Duplicate static route silently ignored (first wins); 404/405 cost O(routes) |
| Middleware | Global `cors` answers every OPTIONS; `logger` prints status 0 when nothing responded; gzip `Vary` only on bodies ≥ 256 B and q-value scan stops at space, not tab |
| gzip | `tdefl_compressor_alloc` nil and `tdefl_init` result unchecked |
| JSON | `snprintf` result unchecked; struct field names written unescaped |
| API | `Ctx` exposes internals as `pub mut` (`buf`, `out`, `chain`, `idx`, …); request counter not on `App`; groups lack `head`/`options` |
| Buffers | Shrink only on close, not when a grown connection goes idle |
| Tests | Positive control for `allocated_bytes()`; alloc guard around `DateCache.format`; `%`-escape in the zero-alloc gate; cumulative chunked cap across chunks; trailers split across reads; exact-32-fields accept; EMFILE path; suite under `-d viltrum_debug`; CI `v fmt -verify` |
| Lint | `router/` not linted; map/array literals not linted (the zero-alloc gate is the real enforcement) |

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
