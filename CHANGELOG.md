# Changelog

From **v0.6.0** onward, entries are produced by [semantic-release](docs/releasing.md) from conventional commits on `main`. Earlier versions were written by hand.

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
