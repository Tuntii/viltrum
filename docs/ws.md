# WebSockets (`ws://`)

Viltrum ships a **first-party** RFC 6455 server on the v0.4 Conn / `app.upgrade` path. Not a wrapper around another stack.

**Status:** v0.5.0 (cleartext). `wss://` is v0.6 (TLS + same WS code).

## Quick start

```v
import viltrum { new, WsSocket }

fn main() {
	mut app := new()
	app.ws('/ws', fn (mut s WsSocket) {
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
import viltrum { WsOptions }

app.ws_opts('/ws', WsOptions{
	max_message_bytes: 1 << 20 // default 1 MiB
	max_frame_bytes:   1 << 20
	auto_pong:         true    // default: reply to ping
	subprotocol:       'chat'  // echoed only if client offered it
	// validate_utf8:  true   // opt-in: invalid text → close 1007
	// check_origin: fn (origin string) bool { return origin == 'https://app.example' }
}, handler)
```

- **Limits are always on** — oversized frames/messages get close **1009** (or fail the read).
- **Fragmented data frames are rejected** (close **1002**) in v0.5; single-frame messages only.
- **Client frames must be masked**; unmasked → protocol error.
- **Origin check is off by default** (tools / non-browser). Set `check_origin` for browsers.
- **UTF-8 validation is off by default** (compat). Set `validate_utf8: true` for strict RFC 6455 text (close **1007** on invalid sequences). Binary frames are never checked.

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

Reverse proxy must forward `Upgrade` and `Connection` hop-by-hop headers and long-lived connections. See [deploy.md](./deploy.md). Docs index: [README.md](./README.md).

## Production readiness (honest)

**Good for:** tools, dashboards, internal services, small multiplayer/demo servers, cleartext behind Caddy/nginx TLS.

**Ship bar met for v0.5:** own framing, limits always on, mask/version checks, close + auto-pong, concurrent echo stress green, message size caps.

| Do | Don't assume |
|----|----------------|
| Put TLS at the reverse proxy until v0.6 | In-process `wss://` |
| Set `ServerOptions` timeouts for long quiet sessions (see below) | Silent “forever idle” without pings or raised deadlines |
| Set `check_origin` for browser clients | Origin protection by default |
| Keep messages under `max_message_bytes` (default 1 MiB) | Unbounded frames |
| Use single-frame messages | Fragmented frames (rejected with close 1002) |
| Opt in `validate_utf8: true` when peers must be strict | UTF-8 validation by default |

### Timeouts after `app.ws` / `app.upgrade`

After a successful hijack, the engine applies **`max(read_timeout, idle_timeout)`** as the Conn read deadline (write still uses `write_timeout`). Defaults: `read_timeout` 30s, `idle_timeout` 60s → upgraded sockets wait **60s** of silence before the next read fails.

| Phase | What applies |
|-------|----------------|
| HTTP request headers/body | `read_timeout` / `read_header_timeout` |
| HTTP keep-alive wait for next request | `idle_timeout` |
| After `app.ws` / `app.upgrade` | read = **max(read_timeout, idle_timeout)**; write = `write_timeout` |

Handlers may call `c.set_read_timeout(...)` (or keep traffic with pings) for longer sessions. Raising both timeouts is the production knob; there is no silent infinite hang by default. Details: [connection.md](./connection.md), [upgrade.md](./upgrade.md).

**Stress / soak:** `bash benches/soak_ws.sh` (CI-friendly defaults; set `SOAK_SECONDS` for longer local runs).

**Known limitations (not bugs of the happy path, but not full RFC completeness):**

- UTF-8 on text is **opt-in** (`validate_utf8`); default still accepts invalid text bytes for compat
- No permessage-deflate / extensions
- Close path is best-effort (send close + TCP close; no long half-open drain)
- One OS thread per connection (same model as HTTP) — fine for thousands of quiet sockets, not a free ticket to millions without tuning
- Treat as a solid **0.5** server, not a mature edge platform; use soak harness before large deploys

## Performance / DX

Framing is first-party and allocation-conscious (tight encode/decode). Handlers stay ergonomic: no unsafe buffers required.

Laptop echo numbers (v0.5.0 `-prod`, Python client — lower bound): single-conn ~**11k msg/s** (64 B); 32 concurrent ~**23k msg/s** aggregate. See [benches/RESULTS.md](../benches/RESULTS.md).
