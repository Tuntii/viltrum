# Viltrum Roadmap

Last updated: 2026-07-19 · current release: **v0.5.0**

Viltrum is a small HTTP framework for [V](https://vlang.io) with its **own** TCP accept loop and HTTP/1.1 framing. Not a thin wrapper.

This document is the product plan. Dates are ordered phases, not calendar promises. Ship when green; skip vanity milestones.

---

## North star

**When someone says “Viltrum,” they mean a first-party engine stack:** own TCP accept, own HTTP/1.1, own connection model, own WebSocket framing, later own TLS path — not a wrapper around another framework’s runtime.

Own the bytes on the wire for tools and services. Tiny public API. Zero third-party deps. Honest benches. Optional `https://` / `wss://` on the **same** Conn story. Never become a full application platform (sessions, ORM, templates).

Success looks like:

- Clone → `bash scripts/install.sh` → `v run examples/*` in minutes
- One mental model from Hello World → mounts → upgrade → `app.ws` → (later) TLS
- Predictable connection lifecycle (keep-alive, idle, limits, graceful stop)
- WebSocket that feels native: `app.ws('/path', handler)` on the hijack foundation, not a bolted-on library
- Performance **and** ergonomics both non-negotiable (see Principles)
- Docs that state what we will **not** do as clearly as what we do

---

## Principles

1. **Small surface** — every public symbol must earn its place.
2. **Own engine, end to end** — accept loop, HTTP framing, Conn, WS frames, and future TLS wrap stay first-party. No silent swap to another stack. No protocol “helpers” that hide a foreign engine.
3. **Performance without DX sacrifice** — speed is a goal; ergonomics and scalable DX are **constraints**. Internal fast paths (pools, codec, later reactor) may grow; the public happy path stays short (`new` → routes → `listen` / `ws`). Never ship “only the ugly path is fast” as the product story.
4. **Honest status** — benches local + method noted; “production” only with evidence.
5. **Proxy-friendly first** — reverse proxy remains valid forever; in-process TLS is additive, not mandatory.
6. **Security before checkboxes** — TLS/WSS land only with tests, limits, and clear failure modes.
7. **No name-drop positioning** — product stands alone in public docs.
8. **YAGNI between phases** — do not start N+1 while N is half-done.

---

## Current baseline (v0.5.0) — done

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
| Minimal JSON field helpers | done |
| Unit + integration tests (`http/`, `router/`, `engine/`, `ws/`), CI, examples | done |

**Explicitly not yet:** in-process TLS / `wss://`, HTTP/2, full JSON codec, sessions, templates, ORM.

---

## Phase map (overview)

```
v0.3.x  Harden + docs + DX           done
v0.4    Conn + hijack / upgrade      done
v0.5    WebSocket (cleartext ws://)  done
v0.6    TLS (https://) then WSS
v0.7+   Polish, multi-listener, ops  (only if demand)
```

TLS/WSS remain planned after WS. Order: hijack-ready conn model → WS framing on plain TCP → TLS wrap → WSS as TLS + WS.

---

## v0.3.x — Harden, document, adopt

**Goal:** Make 0.3.x the boring, trustworthy base. No protocol expansion.

### Docs and product

- [x] README: link this roadmap; short **Non-goals** / **Later** blurb (TLS/WS planned, not now)
- [x] `docs/connection.md`: one connection lifecycle (accept → read → handler → write → idle → close/shutdown)
- [x] `docs/deploy.md`: cleartext behind Caddy/nginx; what proxy must set (`Host`, timeouts)
- [x] Issue labels / tracker issues: `interest:websocket` (#2), `interest:tls` (#1) (collect use-cases, no implementation)
- [x] `docs/request-response.md`: Request/Response, `ctx`, thread-safety

### Engine / HTTP polish (pick by pain, not vanity)

- [x] Chunked / Transfer-Encoding: **reject with 400** + docs (no chunked body support in 0.3.x)
- [x] `Expect: 100-continue` minimal interim response when body still streaming in
- [x] HEAD: engine omits body on the wire; router HEAD falls back to GET; Content-Length kept
- [x] Absolute-form request-target + OPTIONS `*` accepted and documented
- [x] Response `Date` / `Server` headers optional via `ServerOptions` (default off / empty)
- [x] Finer error taxonomy (timeout vs EOF vs protocol/limit) for logs only

### API / DX

- [x] `patch` / `options` / `head` convenience on `App` / `Mount` / `Router`
- [x] Stable `Request`/`Response` docs; when `ctx` is set; thread-safety note
- [x] Deploy notes for reverse proxy (trusted hop) in `docs/deploy.md`
- [x] CI: `v test http/` + `v test router/` + example builds

### Quality bar for exiting 0.3.x

- [x] Roadmap + non-goals visible
- [x] Transfer-Encoding rejected before keep-alive reuse (no TE desync)
- [x] Bench script still runs; RESULTS.md not stale vs claims
- [ ] Tag **v0.3.3** when this branch lands (polish only — not WS/TLS)

---

## v0.4 — Engine foundation (pre-WS / pre-TLS) — **done**

**Goal:** Connection model that can leave pure request/response without hacks.

### Design targets

- [x] **Conn abstraction** (`engine.Conn`): read/write/close/set deadlines; pushback buffer
- [x] **Hijack / upgrade**: `app.upgrade(method, pattern, UpgradeFn)` — one path only
- [x] Leftover ownership: post-message bytes moved into `Conn` pushback (documented in `docs/upgrade.md`)
- [x] `ServerOptions.max_conns` + mutex active counter (excess → **503** + close)
- [x] `read_header_timeout` (0 → `read_timeout`)
- [x] Optional `send_date` / `server_header` on engine HTTP responses
- [x] `Conn.peer_ip` for upgrade handlers
- [x] Transfer-Encoding / Content-Length conflict → 400
- [x] Trailer support: **out of scope**

### Public API (shipped)

```v
app.upgrade('GET', '/echo', fn (mut c viltrum.Conn, req viltrum.Request) {
    c.write_all(viltrum.switching_protocols('echo').to_bytes()) or { return }
    // custom protocol …
    c.close() or {}
})
```

### Tests

- [x] Hijack: 101 then echo (`engine/hijack_test.v`)
- [x] Leftover: pipelined bytes via `buffered_len` + `read`
- [x] Normal HTTP alongside upgrade routes
- [x] TE+CL conflict → 400 on the wire
- [x] max_conns → 503; Date/Server options; peer_ip on upgrade
- [x] Shutdown: listener only; upgrade conns not force-killed (documented)

### Exit

- [x] Design note: `docs/upgrade.md`
- [x] Example: `examples/upgrade_echo`
- [x] 0.4.0 polish (Date/Server, 503, peer_ip, tests)
- [x] Tag **v0.4.0** (https://github.com/Tuntii/viltrum/releases/tag/v0.4.0)

---

## v0.5 — WebSockets (cleartext `ws://`) — **done**

**Goal:** First-party RFC 6455 **server** on the v0.4 Conn/hijack path. Enough for tools, demos, and real small services. **No TLS in this phase.** Same quality bar as HTTP: own framing, limits, tests, ergonomic facade.

**Non-negotiable for this phase (and forever):**

- Own frame codec in-tree (`ws/`) — not a third-party WS package, not a wrapper
- `app.ws` is one line of app code; advanced opts are opt-in
- Message size limits always on; no unbounded buffering
- Performance-minded codec (tight frame parse/write, reusable buffers) without forcing unsafe APIs on handlers
- Does not regress HTTP path ergonomics or benches class without a labeled dual number

### In scope

- [x] Module `viltrum.ws` (`ws/`) — first-party; importable alone or via App facade
- [x] HTTP Upgrade handshake: `Connection: Upgrade`, `Upgrade: websocket`, `Sec-WebSocket-Version: 13`, `Sec-WebSocket-Key` → `Sec-WebSocket-Accept` (RFC golden vector)
- [x] Frame parser/writer: text, binary, close, ping, pong
- [x] Client-to-server masking validation; server-to-client unmasked
- [x] Fragmentation: **reject** fragmented data with close (document; add multi-frame later only if needed)
- [x] Message size limit (`ws.Options.max_message_bytes`, default 1 MiB)
- [x] Close handshake; automatic pong reply to ping (default on)
- [x] Facade: `app.ws(pattern, handler)` / `app.ws_opts(pattern, opts, handler)` on v0.4 hijack
- [x] Example: `examples/ws_echo`
- [x] Docs: `docs/ws.md`
- [x] Tests: handshake golden vectors; frame round-trip; oversized message; bad mask; unit echo path

### Out of scope for v0.5

- permessage-deflate and all extensions
- Subprotocol negotiation beyond optional single `subprotocol` echo if client offered it
- Browser full matrix / Socket.IO / rooms / pubsub framework
- HTTP/2 WebSockets (RFC 8441)
- `wss://` (→ v0.6)
- Client-mode WebSocket (server only this phase)

### Security notes (document in module)

- Origin check: **off by default**, option `check_origin` callback for browser use
- Limits mandatory; no unbounded buffering
- Do not log full payloads in examples

### Exit

- [x] `v run examples/ws_echo` + raw client / `websocat` smoke
- [x] `v test ws/` + existing suites green
- [x] Tag **v0.5.0** (changelog + README status)

---

## v0.6 — TLS (`https://`) then WSS (`wss://`)

**Goal:** In-process TLS for single-binary demos and simple deploys; WSS = TLS listener + WS upgrade. Reverse proxy remains recommended for heavy production edge.

### 0.6a — HTTPS

- [ ] Design note: V stdlib / `net.ssl` (or current V TLS API) capability check; **abort phase if stdlib is inadequate** — document “proxy only” rather than half TLS
- [ ] `ServerOptions` / `TlsOptions`: cert file, key file, optional client CA later
- [ ] `listen_tls(addr, opts)` or `app.listen_tls` parallel to `listen`
- [ ] Conn abstraction from v0.4 wraps SSL stream; deadlines still apply
- [ ] Example: `examples/https_hello` + dev cert script (`scripts/dev-cert.sh`) — dev only, documented
- [ ] Tests: smoke against self-signed; bad cert fail; plain HTTP client to TLS port fails cleanly
- [ ] Docs: cipher/version policy = whatever stdlib defaults unless we must pin; no custom crypto

### 0.6b — WSS

- [ ] Same WS code path as v0.5 over TLS conn (no second WS stack)
- [ ] Example: `examples/wss_echo`
- [ ] Doc: browser `wss://` needs trusted cert or dev exception

### Out of scope for v0.6

- ACME/Let's Encrypt inside Viltrum
- Full mTLS management UI / hot reload of certs (optional later if trivial)
- HTTP/2, ALPN multiplex games beyond what TLS stack needs for HTTPS/1.1
- Being a general TLS terminator competing with Caddy

### Exit

- [ ] Tag **v0.6.0** HTTPS; **v0.6.1** or same tag if WSS lands together when thin enough
- [ ] README status updated: “optional TLS; proxy still fine”

---

## v0.7+ — Backlog (demand-driven)

Only pull when real use or repeated asks:

| Item | Notes |
|------|--------|
| `max_conns` + metrics hook | ops |
| Graceful drain timeout (wait in-flight) | shutdown |
| Multipart / file upload helpers | keep minimal or example-only |
| Better JSON (codegen or opt-in) | not a full serde project by default |
| HTTP/1.1 pipelining stress tests | correctness |
| `http.Client` symmetry | separate product decision |
| Hot reload certs | ops |
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

---

## Suggested implementation order

1. ~~README + non-goals link + interest issues~~ **done**
2. ~~v0.3.x correctness (chunked reject, HEAD, Expect, tests)~~ **done**
3. ~~v0.4 conn + hijack + tests + `docs/upgrade.md`~~ **done**
4. ~~v0.5 `ws` echo + limits + tests + tag~~ **done**
5. v0.6a TLS spike (48h max): stdlib fit? go / no-go ← **next**
6. v0.6a HTTPS listen + example
7. v0.6b WSS example (should be thin)

Do not parallelize 5–7 across half-finished branches.

---

## Public reply stance (community)

When asked about WebSockets / TLS:

- **Yes, on the roadmap** (link here).
- **Hijack foundation is in 0.4** (`app.upgrade` + `Conn`). WS framing is **v0.5**.
- **WS before WSS**; **cleartext WS before in-process TLS** so framing is testable without certs.
- **Proxy + cleartext remains first-class** forever.

---

## Tracking

| Version | Theme | Gate |
|---------|--------|------|
| 0.3.x | Docs, DX, HTTP polish | Suite green, honest README |
| 0.4.0 | Hijack / conn layer | Upgrade echo test |
| 0.5.0 | ws:// | Echo example + frame tests |
| 0.6.x | https:// + wss:// | TLS smoke + WSS echo |
| 0.7+ | Backlog | Demand |

Changelog entries should reference this file when a phase opens or closes.
