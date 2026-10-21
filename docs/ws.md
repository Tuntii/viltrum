# WebSocket (`ws://`, `wss://`)

Viltrum speaks WebSocket (RFC 6455) on the same epoll workers as HTTP. After the `101`, the connection reads
frames instead of requests; your callbacks run on the worker that owns the connection, and a message that
arrived in one frame reaches you as a view into the read buffer, unmasked in place. Echoing a message
allocates nothing.

## Quick start

```v
mut app := viltrum.new()
app.ws('/ws', viltrum.WsHandler{
	on_message: fn (mut s viltrum.Ws, m viltrum.WsMessage) {
		if m.binary {
			s.send_binary(m.data)
		} else {
			s.send_text(m.text())
		}
	}
})
app.listen('127.0.0.1:8084')!
```

```bash
v run examples/ws_echo
websocat ws://127.0.0.1:8084/ws/lobby
```

Over TLS it is the same route: serve it from `app.listen_tls` or a TLS `Listener` and clients connect with
`wss://` ([tls.md](./tls.md)).

## API

| Symbol | Role |
|--------|------|
| `app.ws(pattern, WsHandler, mws...)` | WebSocket on `GET pattern`; also on groups |
| `on_open fn (mut s Ws, mut c Ctx)` | after the `101`; `c` is the upgrade request (params, headers, query) |
| `on_message fn (mut s Ws, m WsMessage)` | each whole message: fragments joined, text checked to be UTF-8 |
| `on_close fn (mut s Ws, code int)` | once, however the connection ends |
| `s.send_text(t)`, `s.send_binary(b)` | one unfragmented message |
| `s.ping(payload)` | a Ping (the client's Pong is absorbed) |
| `s.close(code, reason)` | start the closing handshake |
| `s.data` | `voidptr` for the connection's own state, set in `on_open` |
| `s.protocol()`, `s.worker_id()` | agreed subprotocol, serving worker |
| `m.binary`, `m.data`, `m.text()` | the message; `data` and `text()` are views |

`WsHandler` also takes `max_message` (default 1 MiB), `idle_timeout` (default 120 s, 0 for none), `protocols`
and `check_origin`.

## How it behaves

- **Callbacks run on the connection's worker, one at a time.** Per-connection state in `s.data` needs no
  lock. Like HTTP handlers, callbacks must not block the worker.
- **Views are valid until the callback returns.** `m.data`, `m.text()` and the `Ctx` in `on_open` point into
  connection buffers; `.clone()` what you keep.
- **Sends are buffered and flushed by the event loop**, with the same backpressure as pipelined HTTP: past
  `Options.max_pending` of unsent output, the worker stops reading that connection's frames until the
  client catches up.
- **Middleware runs on the upgrade request.** Global middleware and the `mws` passed to `ws` run before the
  handshake, so an auth check can answer 401 and the connection never upgrades.
- **Ping is answered with Pong automatically.** Unsolicited Pongs are ignored.
- **Closing.** A client's Close is answered with the same code and the connection closes once that is sent.
  `s.close` sends ours; messages that arrive after it are dropped and the connection closes when the
  client answers, or after the read timeout. `on_close` reports the code: the Close's, 1005 for a Close
  without one, 1006 when the connection ended without a Close (reset, timeout, server stop).

## Handshake

| Request | Answer |
|---------|--------|
| no `Upgrade: websocket` (a plain GET) | 426, `Upgrade: websocket` |
| `Sec-WebSocket-Version` other than 13 | 426, `Sec-WebSocket-Version: 13` |
| HTTP/1.0, `Connection` without `upgrade` or with `close`, a body, a malformed `Sec-WebSocket-Key` | 400 |
| `Origin` rejected by `check_origin` | 403 |
| otherwise | 101 with `Sec-WebSocket-Accept`, and `Sec-WebSocket-Protocol` when one of `protocols` was offered |

Browsers send `Origin`; set `check_origin` on browser-facing endpoints so other sites cannot open sockets
with your users' cookies. It is off by default for non-browser clients.

## Limits and errors

A frame that breaks the protocol closes the connection with a Close carrying the code:

| Code | When |
|------|------|
| 1002 | unmasked client frame, RSV bits (no extension is negotiated), unknown opcode, control frame fragmented or over 125 bytes, continuation without a start or a new message inside a fragmented one, bad Close code |
| 1007 | text message or Close reason that is not UTF-8 |
| 1009 | message over `max_message`, judged from the frame header before the payload is read |

## Not supported (yet)

- `permessage-deflate` and other extensions (not negotiated; clients fall back to plain frames).
- Sending outside a callback: there is no handle to write to another connection, so broadcast across
  connections is not possible yet.
- WebSocket over HTTP/2 (RFC 8441): viltrum speaks HTTP/1.1 only.
