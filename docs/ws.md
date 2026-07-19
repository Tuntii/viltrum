# WebSockets (`ws://`)

Viltrum ships a **first-party** RFC 6455 server on the v0.4 Conn / `app.upgrade` path. Not a wrapper around another stack.

**Status:** v0.5.0 (cleartext). `wss://` is v0.6 (TLS + same WS code).

## Quick start

```v
import viltrum

fn main() {
	mut app := viltrum.new()
	app.ws('/ws', fn (mut s viltrum.WsSocket) {
		for {
			msg := s.read_message() or { break }
			if msg.is_text() {
				s.write_text(msg.text()) or { break }
			}
		}
		s.close_quiet()
	})
	app.listen('127.0.0.1:8084') or { panic(err) }
}
```

Demo: `examples/ws_echo` (port **8084**).

```bash
v run examples/ws_echo
websocat ws://127.0.0.1:8084/ws
```

## API

| Symbol | Role |
|--------|------|
| `app.ws(pattern, handler)` | GET upgrade + handshake + `WsHandler` |
| `app.ws_opts(pattern, opts, handler)` | Same with `WsOptions` |
| `WsHandler` | `fn (mut s WsSocket)` |
| `WsSocket.read_message()` | Next text/binary message (handles ping/pong) |
| `WsSocket.write_text` / `write_binary` | Unfragmented data frames |
| `WsSocket.ping` / `pong` / `close` | Control |
| `WsOptions` | Limits, auto-pong, subprotocol, origin check |

Built on **`app.upgrade`**: middleware does **not** run for WS routes (same as other upgrades). See [upgrade.md](./upgrade.md).

## Options

```v
app.ws_opts('/ws', viltrum.WsOptions{
	max_message_bytes: 1 << 20 // default 1 MiB
	max_frame_bytes:   1 << 20
	auto_pong:         true    // default: reply to ping
	subprotocol:       'chat'  // echoed only if client offered it
	// check_origin: fn (origin string) bool { return origin == 'https://app.example' }
}, handler)
```

- **Limits are always on** — oversized frames/messages get close **1009** (or fail the read).
- **Fragmented data frames are rejected** (close **1002**) in v0.5; single-frame messages only.
- **Client frames must be masked**; unmasked → protocol error.
- **Origin check is off by default** (tools / non-browser). Set `check_origin` for browsers.

## Handshake (what we require)

| Check | Result on fail |
|-------|----------------|
| Method `GET` | 405 |
| `Upgrade: websocket` | 400 |
| `Connection` contains `Upgrade` | 400 |
| `Sec-WebSocket-Version: 13` | 426 |
| `Sec-WebSocket-Key` present | 400 |
| Optional `check_origin` | 403 |

Success: **101** + `Upgrade: websocket` + `Sec-WebSocket-Accept` (SHA-1 + GUID, RFC golden vector tested).

## Mental model

```
HTTP accept → parse request → match app.ws route
  → validate handshake → write 101
  → WsSocket owns Conn (pushback leftover included)
  → read_message / write_* until close
```

Same Conn abstraction as custom `app.upgrade` protocols. Future TLS wraps Conn; WS framing does not fork.

## Out of scope (v0.5)

- permessage-deflate / extensions  
- rooms, Socket.IO, pub/sub framework  
- client-mode WebSocket  
- `wss://` (→ v0.6)  
- HTTP/2 WebSockets  

## Proxy notes

Reverse proxy must forward `Upgrade` and `Connection` hop-by-hop headers and long-lived connections. See [deploy.md](./deploy.md).

## Production readiness (honest)

**Good for:** tools, dashboards, internal services, small multiplayer/demo servers, cleartext behind Caddy/nginx TLS.

**Ship bar met for v0.5:** own framing, limits always on, mask/version checks, close + auto-pong, concurrent echo stress green, message size caps.

| Do | Don't assume |
|----|----------------|
| Put TLS at the reverse proxy until v0.6 | In-process `wss://` |
| Raise `read_timeout` / `write_timeout` for idle sockets (defaults are HTTP-oriented, often 30s) | Silent “forever idle” without pings |
| Set `check_origin` for browser clients | Origin protection by default |
| Keep messages under `max_message_bytes` (default 1 MiB) | Unbounded frames |
| Use single-frame messages | Fragmented frames (rejected with close 1002) |

**Known limitations (not bugs of the happy path, but not full RFC completeness):**

- No UTF-8 validation on text payloads (invalid UTF-8 is not auto-closed with 1007)
- No permessage-deflate / extensions
- Close path is best-effort (send close + TCP close; no long half-open drain)
- One OS thread per connection (same model as HTTP) — fine for thousands of quiet sockets, not a free ticket to millions without tuning
- Not multi-year production soak-tested; treat as a solid **0.5** server, not a mature edge platform

## Performance / DX

Framing is first-party and allocation-conscious (tight encode/decode). Handlers stay ergonomic: no unsafe buffers required.

Laptop echo numbers (v0.5.0 `-prod`, Python client — lower bound): single-conn ~**11k msg/s** (64 B); 32 concurrent ~**23k msg/s** aggregate. See [benches/RESULTS.md](../benches/RESULTS.md).
