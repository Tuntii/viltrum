# Connection upgrade / hijack (v0.4)

How Viltrum leaves pure HTTP request/response and hands the byte stream to your code.

This is the foundation for **WebSocket (`ws://`)** ([ws.md](./ws.md)) and later **TLS-wrapped streams**.

---

## One path

```v
import viltrum { Conn, Request, switching_protocols }

app.upgrade('GET', '/echo', fn (mut c Conn, req Request) {
	resp := switching_protocols('echo')
	c.write_all(resp.to_bytes()) or { return }
	// ... custom protocol on c ...
	c.close() or {}
})
```

There is **no** second style (no Response flag, no competing hijack APIs).  
Register upgrade routes with `app.upgrade(method, pattern, handler)`.

Patterns support the same `:param` and trailing `*wildcard` rules as the HTTP router.

---

## Lifecycle

```
accept
  → read full HTTP message (headers + Content-Length body)
  → if upgrade route matches:
        wrap TCP as engine.Conn (pushback = bytes past this message)
        call UpgradeFn(mut conn, req)
        HTTP loop ENDS for this socket
        engine closes conn if handler did not
  → else: normal handler → write Response → keep-alive / close
```

### What “hijack” means here

After a match:

1. The keep-alive HTTP loop **does not** run again on this connection.
2. **You** write the status line (almost always `101 Switching Protocols`) and any protocol headers.
3. **You** own all further reads/writes until `close`.

### What is *not* done automatically

- No automatic `101` (you choose headers: `Upgrade`, `Sec-WebSocket-*`, etc.).
- Global `app.use` middleware **does not** run for upgrade routes (by design in 0.4).
- Shutdown (SIGINT/SIGTERM) closes the **listener** only. In-flight upgrade conns keep running until the handler or peer closes them. They are not force-drained.

---

## `Conn` and leftover ownership

`Conn` (type alias of `engine.Conn`; import with `import viltrum { Conn, … }`) is the stream API:

| Method | Role |
|--------|------|
| `read` / `read_exact` | Pushback first, then socket |
| `write` / `write_all` | Socket write |
| `set_read_timeout` / `set_write_timeout` | Deadlines |
| `close` | Idempotent; engine closes if you return without it |
| `buffered_len` | Bytes waiting in pushback |

### Leftover / pushback (critical)

While reading the HTTP request, the engine may have already consumed **extra** bytes after the end of that message (client pipelining or “data right after headers”).

Those bytes are **moved** into the `Conn` pushback buffer before `UpgradeFn` runs.

Rules:

1. **Single owner:** only `Conn.read` returns them. There is no separate `leftover []u8` argument (avoids double-delivery bugs).
2. **Before socket reads:** `buffered_len() > 0` means protocol data is already available.
3. **Do not assume** the first `read` hits the kernel; it may only drain pushback.
4. After upgrade, the engine’s HTTP leftover buffer for that task is empty and discarded.

### Request body policy

The upgrade decision runs **after** a full HTTP message read:

- Body is present on `req.body` when `Content-Length` was set (same as normal requests).
- `Transfer-Encoding` remains unsupported; TE+`Content-Length` → **400 conflict**.

For typical upgrades (`GET` with no body), `req.body` is empty and pushback is only post-message bytes.

---

## `engine.Conn` vs raw TCP

All new non-HTTP protocols should use `Conn`, not `net.TcpConn` directly:

- Same surface later for TLS (v0.6).
- Pushback is correct for early data.
- Timeouts stay explicit.

---

## Limits related to upgrades

| Option | Effect |
|--------|--------|
| `max_conns` | Caps concurrent accepted connections (HTTP + upgrade). Excess accepts get **503** + `Connection: close`, then TCP close. |
| `read_header_timeout` | Header assembly phase; `0` → use `read_timeout`. |
| `read_timeout` / `write_timeout` | Applied on the `Conn` before your handler runs; change them in-handler if needed. |
| `idle_timeout` | Only for HTTP keep-alive wait **before** the next request. After hijack, idle is your problem. |
| `send_date` / `server_header` | Apply to normal HTTP responses only — **not** to upgrade-written bytes. |

### `Conn.peer_ip`

After hijack, `c.peer_ip()!` returns the remote address string (typically `127.0.0.1:…` or similar). Useful for logging; not a security boundary by itself.

---

## Minimal 101 helper

```v
resp := viltrum.switching_protocols('websocket') // or 'echo', etc.
c.write_all(resp.to_bytes())!
```

Adds `Connection: Upgrade` and optional `Upgrade: …`.  
Add WebSocket handshake headers yourself in v0.5+ code (or custom protocols).

---

## Example

`examples/upgrade_echo` — cleartext echo after `101`.

```bash
v run examples/upgrade_echo
# other terminal:
printf 'GET /echo HTTP/1.1\r\nHost: localhost\r\n\r\nhello\n' | nc 127.0.0.1 8083
```

---

## Shutdown behaviour (defined)

| Phase | Behaviour |
|-------|-----------|
| Signal | Listener closes; accept loop exits |
| Active HTTP handlers | Finish or fail on write; conn closed by engine |
| Active upgrade handlers | **Not** interrupted by the server; run until handler/`close`/peer EOF |
| New accepts | Stop |

This is intentional for v0.4 simplicity. A future “drain” mode may track and close hijacked conns (roadmap backlog).

---

## Non-goals (v0.4)

- ~~WebSocket framing / `app.ws`~~ → see [ws.md](./ws.md) (v0.5 on main)
- TLS / WSS
- Middleware chain on upgrade routes
- Multiple hijack APIs
- HTTP/2 connect/upgrade

**v0.5** builds `ws://` on this exact `app.upgrade` + `Conn` contract — see [ws.md](./ws.md).
