# Viltrum Roadmap

Last updated: 2026-08-06 · current release: **v0.7.8**

Viltrum is a small HTTP framework for [V](https://vlang.io) with its **own** TCP accept loop and HTTP/1.1 framing. Not a thin wrapper.

This document is the product plan. Dates are ordered phases, not calendar promises. Ship when green; skip vanity milestones.

---

## North star

**When someone says “Viltrum,” they mean a first-party engine stack:** own TCP accept, own HTTP/1.1, own connection model, own WebSocket framing, own optional TLS path — not a wrapper around another framework’s runtime.

Own the bytes on the wire for tools and services. Tiny public API. Zero third-party deps. Honest benches. Optional `https://` / `wss://` on the **same** Conn story. Never become a full application platform (sessions, ORM, templates).

Success looks like:

- Clone → `bash scripts/install.sh` → `v run examples/*` in minutes
- One mental model from Hello World → mounts → upgrade → `app.ws` → TLS
- Predictable connection lifecycle (keep-alive, idle, limits, graceful stop)
- WebSocket that feels native: `app.ws('/path', handler)` on the hijack foundation
- Performance **and** ergonomics both non-negotiable (see Principles)
- Docs that state what we will **not** do as clearly as what we do
- A full-stack teaching starter (separate repo) so new users see API + UI without bloating the engine

---

## Principles

1. **Small surface** — every public symbol must earn its place.
2. **Own engine, end to end** — accept loop, HTTP framing, Conn, WS frames, and TLS wrap stay first-party. No silent swap to another stack. No protocol “helpers” that hide a foreign engine.
3. **Performance without DX sacrifice** — speed is a goal; ergonomics and scalable DX are **constraints**. Internal fast paths (pools, codec, experimental reactor) may grow; the public happy path stays short (`new` → routes → `listen` / `ws`). Never ship “only the ugly path is fast” as the product story.
4. **Honest status** — benches local + method noted; “production” only with evidence.
5. **Proxy-friendly first** — reverse proxy remains valid forever; in-process TLS is additive, not mandatory.
6. **Security before checkboxes** — TLS/WSS land only with tests, limits, and clear failure modes.
7. **No name-drop positioning** — product stands alone in public docs.
8. **YAGNI between phases** — do not start N+1 while N is half-done.

---

## Current baseline (v0.7.8) — done

| Area | Status |
|------|--------|
| TCP accept + spawn per conn | done (`engine/`) |
| HTTP/1.1 parse/serialize, keep-alive, Host check | done (`http/`) |
| Limits: header/body size, read/write/idle/header timeouts, `max_conns` | done |
| Graceful shutdown (SIGINT/SIGTERM), `handle_signals` | done |
| Router: method, `:param`, `*wildcard`, slash normalize, HEAD→GET | done |
| App facade, mount, chain, cors, static, logger, recover | done |
| **`engine.Conn` + `app.upgrade` hijack** | done (v0.4) |
| **`app.ws` + `viltrum.ws` RFC 6455** (`ws://`) | done (v0.5) |
| **In-process HTTPS / WSS** (`listen_tls`, mbedtls) | done (v0.7.0 line; design was “v0.6”) |
| HTTP/1.1 hot-path PR1–PR7 (honest ceiling documented) | done (v0.7.1–0.7.6) |
| HeaderMap lowered hot path; experimental conn pool / epoll | done (v0.7.7–0.7.8; opt-in / default off) |
| Full-stack teaching starter | done ([full-stack-viltrum-template](https://github.com/Tuntii/full-stack-viltrum-template)) |
| Minimal JSON field helpers | done |
| Unit + integration tests, CI, examples | done |

**Explicitly not in tree as product:** ORM, sessions platform, templates engine, HTTP/2–3, edge ACME terminator.

---

## Phase map (overview)

```
v0.3.x  Harden + docs + DX              done
v0.4    Conn + hijack / upgrade         done
v0.5    WebSocket (cleartext ws://)     done
v0.5.x  Engine harden + measured perf   done (epic #3)
v0.6*   TLS (https://) then WSS         done (shipped on 0.7.0 line)
v0.7.x  Hot path + polish + starter     done through 0.7.8
v0.8+   Demand-driven backlog           open
```

\*Roadmap originally numbered TLS as **v0.6** and hot path as **v0.8**. Releases used **0.7.x** for both after 0.6.x patch history. Treat version themes below as source of truth; do not renumber old tags.

---

## v0.3.x — Harden, document, adopt — **done**

**Goal:** Make 0.3.x the boring, trustworthy base. No protocol expansion.

### Docs and product

- [x] README: link this roadmap; short **Non-goals** / **Later** blurb
- [x] `docs/connection.md`, `docs/deploy.md`, `docs/request-response.md`
- [x] Interest issues: WebSocket (#2), TLS (#1)

### Engine / HTTP polish

- [x] Chunked / TE reject with 400; Expect: 100-continue; HEAD body omit
- [x] Absolute-form request-target + OPTIONS `*`
- [x] Optional `Date` / `Server`; finer error taxonomy for logs

### API / DX

- [x] `patch` / `options` / `head` convenience
- [x] CI: unit tests + example builds

---

## v0.4 — Engine foundation (pre-WS / pre-TLS) — **done**

**Goal:** Connection model that can leave pure request/response without hacks.

- [x] `engine.Conn`, `app.upgrade`, leftover pushback
- [x] `max_conns`, `read_header_timeout`, `send_date` / `server_header`, `peer_ip`
- [x] Docs: `docs/upgrade.md`; example: `examples/upgrade_echo`
- [x] Tag **v0.4.0**

---

## v0.5 — WebSockets (cleartext `ws://`) — **done**

**Goal:** First-party RFC 6455 **server** on the v0.4 Conn/hijack path.

- [x] `viltrum.ws`, handshake, frames, limits, `app.ws` / `app.ws_opts`
- [x] Example `examples/ws_echo`, docs `docs/ws.md`, tests
- [x] Tag **v0.5.0**

### Out of scope for v0.5 (still)

- permessage-deflate; full subprotocol matrix; Socket.IO; client-mode WS; RFC 8441

---

## v0.5.x — Engine harden + measured perf — **done**

Epic [#3](https://github.com/Tuntii/viltrum/issues/3): timeouts, soak, first-party WS load client, HTTP profile micro-opts. No architecture rewrite.

---

## v0.6 theme — TLS (`https://`) then WSS (`wss://`) — **done**

Shipped on the **v0.7.0** release line (see CHANGELOG). Design: [docs/design/v0.6-tls-wss.md](docs/design/v0.6-tls-wss.md).

### HTTPS + WSS

- [x] `TlsOptions`, `app.listen_tls`, Conn dual transport (tcp | ssl)
- [x] Same WS path over TLS (`examples/wss_echo`)
- [x] Dev cert script, docs `docs/tls.md`

### Out of scope (still)

- ACME inside Viltrum; full mTLS management UI; competing with Caddy as edge terminator

---

## v0.7.x — HTTP/1.1 hot path + ops spikes — **done** (through 0.7.8)

**Goal:** Own-stack cleartext HTTP/1.1 throughput toward a competitive peer band; document honesty when the bar is not met.

| PR / work | Status |
|-----------|--------|
| PR1 Instrument + baseline lock | done |
| PR2 Byte-level `parse_request` | done |
| PR3 Single message ownership | done |
| PR4 Response `[]u8` builder + header casing cache | done |
| PR5 Conn-local buffer reuse | done |
| PR6 `SO_REUSEPORT` multi-listener experiment | done (default off) |
| PR7 Honest RESULTS closeout | done |
| HeaderMap lowered hot path | done (0.7.8) |
| Experimental `conn_workers` pool | done (opt-in; 0.7.7) |
| Experimental Linux epoll reactor | done (opt-in; default off; A/B notes) |

### Exit (epic #16)

- [x] League bar checked: **not met** (E ~98k / ~0.51× Axum on 2026-08-05 laptop run)
- [x] Honest ceiling in [benches/RESULTS.md](./benches/RESULTS.md)
- [x] No public API break

**Remaining gap** is largely runtime / scheduler / syscall stack (V spawn-per-conn + std `net` vs Tokio multi-thread), not a single missing clone on the HTTP path. Further absolute gains need runtime-level work, not another HTTP-only clone epic.

---

## Teaching surface — full-stack starter — **done** (separate repo)

Inspired by [fastapi/full-stack-fastapi-template](https://github.com/fastapi/full-stack-fastapi-template); **not a port**.

- [x] **[Tuntii/full-stack-viltrum-template](https://github.com/Tuntii/full-stack-viltrum-template)** — same-process API + static SPA, bearer auth, users, items, in-memory store
- [x] Own git history, MIT license, `scripts/setup.sh` to link Viltrum
- [x] Linked from this repo’s README / docs / examples index

Lives **outside** the engine tree so app churn does not couple to framework releases. Does **not** add ORM, Docker Compose, or React toolchain to Viltrum.

---

## v0.8+ — Backlog (demand-driven)

Only pull when real use or repeated asks:

| Item | Notes |
|------|--------|
| Graceful drain timeout (wait in-flight) | shutdown |
| `max_conns` + metrics / ops hooks | observability |
| Multipart / file upload helpers | keep minimal or example-only |
| Better JSON (codegen or opt-in) | not a full serde project by default |
| HTTP/1.1 pipelining stress tests | correctness |
| `http.Client` symmetry | separate product decision |
| Hot reload certs | ops |
| Runtime-level perf (scheduler / I/O) | only with measured design; epoll spike already documented |
| RFC 8441 WS over H2 | almost certainly never |
| HTTP/2, HTTP/3 | **not planned** unless strategy changes |
| Middleware ecosystem / plugin repo | community first |

---

## Non-goals (standing)

Unless this file is explicitly revised:

- Competing as edge TLS terminator / multi-tenant gateway
- Application platform: sessions, auth providers, template engine, ORM
- Wrapping another language’s framework
- Guaranteeing multi-hundred-k RPS on laptop benches as product claim
- Implementing full RFC surface “for completeness”
- Shipping the FastAPI monorepo feature list inside Viltrum

---

## Suggested implementation order (historical)

1. ~~README + non-goals + interest issues~~ **done**
2. ~~v0.3.x correctness~~ **done**
3. ~~v0.4 conn + hijack~~ **done**
4. ~~v0.5 `ws`~~ **done**
5. ~~TLS + WSS~~ **done** (0.7.0)
6. ~~HTTP/1.1 hot path PR1–PR7~~ **done**
7. ~~Full-stack teaching starter~~ **done**
8. **Next:** demand-driven items from **v0.8+ backlog** only

Do not open a parallel mega-epic without closing criteria and honest benches.

---

## Public reply stance (community)

When asked about WebSockets / TLS / “full stack”:

- **WS and TLS are shipped** (`app.ws`, `app.listen_tls`). Proxy + cleartext remains first-class.
- **Full-stack starter:** [full-stack-viltrum-template](https://github.com/Tuntii/full-stack-viltrum-template) — inspired by the FastAPI full-stack template, not a clone of its infrastructure.
- **Hijack foundation** is `app.upgrade` + `Conn` (since 0.4).
- **Performance:** honest numbers in `benches/RESULTS.md`; we do not invent parity with Tokio.

---

## Tracking

| Version / theme | Theme | Gate |
|-----------------|--------|------|
| 0.3.x | Docs, DX, HTTP polish | Suite green, honest README |
| 0.4.0 | Hijack / conn layer | Upgrade echo test |
| 0.5.0 | ws:// | Echo example + frame tests |
| 0.5.x | Harden + measured perf | Epic #3 children |
| 0.7.0 | https:// + wss:// | TLS smoke + WSS echo |
| 0.7.1–0.7.8 | Hot path + experiments + starter docs | RESULTS + build green |
| 0.8+ | Backlog | Demand |

Changelog entries should reference this file when a phase opens or closes.
