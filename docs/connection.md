# Connection lifecycle

How one TCP connection moves through Viltrum’s HTTP/1.1 engine (`engine/`).

```
accept
  → read headers (+ body if Content-Length)
  → parse Request
  → Host check (HTTP/1.1)
  → upgrade route match? ──yes──▶ Conn ownership → UpgradeFn → close (no keep-alive loop)
  → handler
  → write Response
  → keep-alive idle wait  ─┐
  → close / shutdown       │
       ↑___________________┘  (next request on same conn)
```

Upgrade/hijack details: [upgrade.md](./upgrade.md).

## Accept

`listen_and_serve_opt` binds TCP and `accept`s in a loop. Each accepted conn is handled in its own spawned task (`handle_conn`). SIGINT/SIGTERM (when `handle_signals` is true) close the listener and end the accept loop; in-flight handlers are not drained with a timeout (see roadmap v0.7+).

## Read

1. **Idle vs active timeout.** After the first message on a connection, the next read uses `idle_timeout`. Once bytes arrive for a new request, `read_timeout` applies again.
2. **Headers.** Bytes accumulate until `\r\n\r\n`. Cap: `max_header_bytes` → 413 / error close.
3. **Body.** Only **`Content-Length`** bodies are read. Size must be ≤ `max_body_bytes`.
4. **Chunked / Transfer-Encoding.** Not supported. Request is rejected with **400** and the connection is closed (no keep-alive desync).
5. **Leftover.** Extra bytes after the message stay in a per-conn buffer for the next request (pipelining-tolerant read path). Full HTTP/1.1 pipelining is not a product claim.

## Parse and validate

`http.parse_request` builds method, target, normalized path, query, headers, body.

- HTTP/1.1 requires a **Host** header when `require_host` is true (default).
- Absolute-form targets (`http://host/path`) are reduced to path + query when parsing.
- `OPTIONS *` is accepted as path `*` (no special router magic).

## Handler

The app/router runs and returns a `Response`. `req.ctx` is set from `App.set_ctx` before the handler runs. Shared mutable state behind `ctx` is the caller’s responsibility (use a mutex if needed).

## Write

Response is serialized as HTTP/1.1 status line + headers + body.

- **HEAD:** the engine strips the response body before write but keeps `Content-Length` as the handler set it (same as GET would have returned).
- **Connection:** `should_close` considers response `Connection: close`, request `Connection: close`, and HTTP/1.0 default close unless keep-alive.

## Idle and close

If keep-alive: loop waits for the next request with `idle_timeout`. On timeout, EOF, protocol error, or close decision, the conn is closed.

## Expect: 100-continue

If the request includes `Expect: 100-continue` and a non-negative `Content-Length`, the engine sends a minimal **`100 Continue`** interim response before finishing the body read (when the body is not already fully buffered). Other `Expect` values are ignored (not treated as errors).

## Limits (defaults)

| Option | Default |
|--------|---------|
| `max_header_bytes` | 64 KiB |
| `max_body_bytes` | 1 MiB |
| `read_timeout` | 30s |
| `write_timeout` | 30s |
| `idle_timeout` | 60s |
| `read_header_timeout` | 0 (= `read_timeout`) |
| `max_conns` | 0 (unlimited); excess accepts get **503** + close |
| `send_date` | false — when true, add `Date` if handler omitted it |
| `server_header` | `""` — when non-empty, add `Server` if handler omitted it |

`Date` / `Server` apply only to engine-written HTTP responses (including 4xx/5xx). Upgrade handlers write their own bytes and are not auto-annotated.

See `engine.ServerOptions` and [deploy.md](./deploy.md) for reverse-proxy timeout alignment.
