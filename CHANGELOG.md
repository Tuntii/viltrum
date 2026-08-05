# Changelog

## [0.7.9](https://github.com/Tuntii/viltrum/compare/v0.7.8...v0.7.9) (2026-08-05)

### Performance Improvements

* **http:** experimental Linux epoll reactor (opt-in, default off) ([79adb02](https://github.com/Tuntii/viltrum/commit/79adb02f41e8c375f4934a279e514d146ad9916e))

## [0.7.8](https://github.com/Tuntii/viltrum/compare/v0.7.7...v0.7.8) (2026-08-05)

### Performance Improvements

* **http:** HeaderMap lowered hot path without extra to_lower ([ada4acb](https://github.com/Tuntii/viltrum/commit/ada4acb5d2ac3bed9a4a293df394ac051a631d20))

## [0.7.7](https://github.com/Tuntii/viltrum/compare/v0.7.6...v0.7.7) (2026-08-05)

### Performance Improvements

* **http:** experimental conn_workers pool (blocking) + A/B note ([50b5d4a](https://github.com/Tuntii/viltrum/commit/50b5d4a5139e278345ca263fdfbf7c9b3565042c))

## [0.7.6](https://github.com/Tuntii/viltrum/compare/v0.7.5...v0.7.6) (2026-08-04)

### Performance Improvements

* **http:** PR6 SO_REUSEPORT multi-listener experiment ([#22](https://github.com/Tuntii/viltrum/issues/22)) ([63e516d](https://github.com/Tuntii/viltrum/commit/63e516d8583d388e2204ac6056d8b1d1679c8d01)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)

## [0.7.5](https://github.com/Tuntii/viltrum/compare/v0.7.4...v0.7.5) (2026-08-04)

### Performance Improvements

* **http:** PR5 conn-local assembly and write buffer reuse ([#21](https://github.com/Tuntii/viltrum/issues/21)) ([bf4b78c](https://github.com/Tuntii/viltrum/commit/bf4b78c1b4204a5de523adb0d44cee3705867253)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)

## [0.7.4](https://github.com/Tuntii/viltrum/compare/v0.7.3...v0.7.4) (2026-08-04)

### Performance Improvements

* **http:** PR4 response []u8 builder and header casing cache ([#20](https://github.com/Tuntii/viltrum/issues/20)) ([32a3284](https://github.com/Tuntii/viltrum/commit/32a32845dce657fe64a42190f5de750df070a0ae)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)

## [0.7.3](https://github.com/Tuntii/viltrum/compare/v0.7.2...v0.7.3) (2026-08-04)

### Performance Improvements

* **http:** PR3 single message ownership, no double body clone ([#19](https://github.com/Tuntii/viltrum/issues/19)) ([39b7d14](https://github.com/Tuntii/viltrum/commit/39b7d14ccdf1764a7b55c30a88d1b2b54e03afdf)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)

## [0.7.2](https://github.com/Tuntii/viltrum/compare/v0.7.1...v0.7.2) (2026-07-29)

### Performance Improvements

* **http:** polish PR2 parse_request helpers and edge tests ([#18](https://github.com/Tuntii/viltrum/issues/18)) ([d66e238](https://github.com/Tuntii/viltrum/commit/d66e238e06731ce149b3fc424d7bad215fdfe648))
* **http:** PR2 parse_request byte walk without full bytestr ([#18](https://github.com/Tuntii/viltrum/issues/18)) ([6eef34c](https://github.com/Tuntii/viltrum/commit/6eef34c6db377663d5d1c8b40098203f51c86973))

## [0.7.1](https://github.com/Tuntii/viltrum/compare/v0.7.0...v0.7.1) (2026-07-28)

### Performance Improvements

* **http:** PR1 Axum compare harness and hot-path epic baseline ([#17](https://github.com/Tuntii/viltrum/issues/17)) ([227ae9a](https://github.com/Tuntii/viltrum/commit/227ae9af805b7bc8eca31a8e12b607d6bf33c7ec)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)
* **http:** PR1 baseline harness without design doc share ([#17](https://github.com/Tuntii/viltrum/issues/17)) ([fec76eb](https://github.com/Tuntii/viltrum/commit/fec76ebf4043adec7406eb457b01d0310ec54d1f))

## [0.7.0](https://github.com/Tuntii/viltrum/compare/v0.6.1...v0.7.0) (2026-07-28)

### Features

* **tls:** in-process HTTPS and WSS via mbedtls ([#1](https://github.com/Tuntii/viltrum/issues/1)) ([00ab6c0](https://github.com/Tuntii/viltrum/commit/00ab6c0899c14671f31045a839d14ec34ac7648a))

## [0.6.1](https://github.com/Tuntii/viltrum/compare/v0.6.0...v0.6.1) (2026-07-23)

### Performance Improvements

* **http:** reuse read scratch and cheaper CL/TE scan ([#9](https://github.com/Tuntii/viltrum/issues/9)) ([34c2a13](https://github.com/Tuntii/viltrum/commit/34c2a134652a68e58a5f33ad53146974dbd3184d))

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
