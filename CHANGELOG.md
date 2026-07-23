# Changelog

## [0.6.0](https://github.com/Tuntii/viltrum/compare/v0.5.2...v0.6.0) (2026-07-23)

### Features

* **bench:** first-party V WS load client and CI soak ([fc9f626](https://github.com/Tuntii/viltrum/commit/fc9f6269d3febe6523caa59d3708d27944d74582))

## [0.5.2](https://github.com/Tuntii/viltrum/compare/v0.5.1...v0.5.2) (2026-07-23)

### Bug Fixes

* **ws:** idle timeouts, UTF-8 opt-in, soak harness, Conn ref ([356a5eb](https://github.com/Tuntii/viltrum/commit/356a5ebb561824ea8b154d1cded4a6c094a11139)), closes [#4](https://github.com/Tuntii/viltrum/issues/4) [#8](https://github.com/Tuntii/viltrum/issues/8) [#5](https://github.com/Tuntii/viltrum/issues/5) [#6](https://github.com/Tuntii/viltrum/issues/6)

## [0.5.1](https://github.com/Tuntii/viltrum/compare/v0.5.0...v0.5.1) (2026-07-19)

### Bug Fixes

* keep accept loop alive when handle_signals is on ([2a3b3dc](https://github.com/Tuntii/viltrum/commit/2a3b3dc6af30a9a4a532cea1704e96b4d00f5745)), closes [#11](https://github.com/Tuntii/viltrum/issues/11)

From **v0.6.0** onward, entries are produced by [semantic-release](docs/releasing.md) from conventional commits on `main`. Earlier versions were written by hand.

## Unreleased (0.5.x)

### Hardening

- After `app.upgrade` / `app.ws`, Conn read deadline is `max(read_timeout, idle_timeout)` so quiet long-lived streams survive past the short HTTP request timeout (#4)
- Opt-in UTF-8 validation on text frames: `WsOptions{ validate_utf8: true }` closes with **1007** on invalid sequences; default remains off for compat (#8)
- Soak / close-storm harness: `bash benches/soak_ws.sh` (multi-conn echo + rapid open/close; optional `SOAK_SECONDS`) (#5)
- **Fix:** `WsSocket` holds `Conn` by reference (was a copy). Closing the socket then returning to the engine double-closed the TCP fd and raced new accepts under close-storm load
- Soak health check no longer requires `curl` (python sockets); CI runs a short soak + builds the V load client

### Performance

- WS server write path reuses an internal encode scratch buffer (`encode_server_into`) — public `write_text` / `write_binary` / `write_message` unchanged (#6)
- First-party V WS load client: `benches/ws_load_client.v`; `run_ws.sh` defaults to it (`CLIENT=python` keeps optional smoke) (#7)
- WS headline re-baseline (V client): multi-conn aggregate ~**30–40k msg/s** on developer laptop (method noted in `benches/RESULTS.md`)
- HTTP accept/read/write profile note (`benches/HTTP_PROFILE.md`) plus two micro-opts (#9): reuse `read_message` scratch `tmp` across keep-alive requests; engine Content-Length / Transfer-Encoding pre-scan is a byte-level field walk (no full-header `bytestr`+`split`+`to_lower`). No public API change; `RESULTS.md` unchanged (no oha re-run; expected win below the ~10% material bar without measurement)

## 0.5.0 — 2026-07-19

### WebSocket (`ws://`) — first-party engine

- New module `viltrum.ws`: RFC 6455 server framing on `engine.Conn` (not a third-party wrapper)
- `app.ws(pattern, handler)` / `app.ws_opts(pattern, opts, handler)` — handshake + `WsSocket` loop
- Handshake: `Upgrade: websocket`, version 13, `Sec-WebSocket-Accept` (RFC golden vector tested)
- Frames: text, binary, close, ping, pong; client mask required; server unmasked
- Fragmented data rejected (close 1002); message/frame size limits (default 1 MiB)
- Auto-pong (default on); optional `subprotocol` echo; optional `check_origin`
- Example: `examples/ws_echo` · Docs: `docs/ws.md`
- Tests: `v test ws/`

North star: performance and ergonomics stay non-negotiable; WS sits on the same Conn story as HTTP upgrade. `wss://` is v0.6.

## 0.4.0 — 2026-07-19

### Engine / upgrade

- `engine.Conn`: read/write/close/deadlines + pushback buffer for post-message bytes
- `Conn.peer_ip` for upgrade/logging
- `app.upgrade(method, pattern, handler)` — single hijack path; HTTP loop stops for that conn
- `viltrum.switching_protocols` / `Response.switching_protocols` for bare 101 responses
- `ServerOptions.max_conns` — excess accepts get **503** + close
- `ServerOptions.read_header_timeout`
- `ServerOptions.send_date` / `server_header` (opt-in; do not overwrite handler headers)
- `http.http_date` / `viltrum.http_date` for IMF-fixdate
- TE + Content-Length conflict → 400
- Example: `examples/upgrade_echo`
- Design note: `docs/upgrade.md`
- Integration tests: 101 echo, leftover, Date/Server, max_conns 503, peer_ip
- CI runs `v test engine/` and builds upgrade example

### From 0.3.x polish (shipped in this line)

- Docs: connection, deploy, request-response; README non-goals
- Chunked/TE reject; Expect 100-continue; HEAD body omit + GET fallback
- Absolute-form target, OPTIONS `*`; `patch`/`options`/`head`
- `App.server_options` (renamed from `options` for ServerOptions)

## 0.3.2 — 2026-07-18

- Trailing wildcard routes: `/files/*path`
- JSON field helpers: `req.json_string` / `json_int` / `json_bool` (minimal)
- Route middleware: `viltrum.chain([...], handler)` and `Mount.use`
- `scripts/install.sh` for `~/.vmodules` link
- Heavier bench notes (JSON body + higher concurrency)
- features example: wildcard, chain, mount header, json echo

## 0.3.1 — 2026-07-18

- `app.mount`, cors, static_files, parse fuzz, honest oha bench, GitHub Release

## 0.3.0 — 2026-07-18

- Graceful shutdown, idle timeout, recover, timed logger

## 0.2.x — 2026-07-18

- Framing, keep-alive, polish

## 0.1.0 — 2026-07-18

- Initial PoC
