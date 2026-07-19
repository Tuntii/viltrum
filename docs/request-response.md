# Request and Response

Stable notes for the public HTTP types re-exported by `viltrum` (`viltrum.http`).

## Import

```v
import viltrum {
	Request
	Response
	text
	json
	empty
	not_found
	chain
	// Handler, Middleware if you type them yourself
}
```

Then use `Request`, `Response`, `text(...)` without a `viltrum.` prefix. Fully qualified (`viltrum.Request`) remains valid.

## Request

| Field / API | Meaning |
|-------------|---------|
| `method` | As on the request line (`GET`, `POST`, …). |
| `target` | Raw request-target (may be absolute-form or `*`). |
| `path` | Normalized path (`/` root, no trailing slash except root). Absolute-form reduced to path. `OPTIONS *` → path `*`. |
| `query` | Raw query string without `?`. |
| `version` | e.g. `HTTP/1.1`. |
| `headers` | Case-insensitive map; duplicate field-lines combined with `, `. |
| `body` | Raw bytes; only filled from `Content-Length`. |
| `params` | Router path params (`:id`, `*path`). Empty until the router matches. |
| `ctx` | `voidptr` set by the app before the handler runs (`App.set_ctx`). |

Helpers: `param`, `query_param`, `text`, `json_string` / `json_int` / `json_bool` (minimal, not a full JSON codec).

### Thread-safety

Each request is handled on one conn task. **`ctx` is shared across requests** if you set one app-wide pointer. Concurrent mutation of data behind `ctx` requires your own synchronization. Do not assume request handlers are single-threaded process-wide.

## Response

| Field / API | Meaning |
|-------------|---------|
| `status` / `reason` | Status code and reason phrase. |
| `headers` | Written as-is (canonicalized names on serialize). |
| `body` | Entity body. For **HEAD**, the engine omits body bytes on the wire but keeps headers (including `Content-Length`). |

Constructors: `Response.text`, `.json`, `.empty`, `.not_found`, `.method_not_allowed`, `.bad_request`, `.switching_protocols`. Builder: `.header`, `.set_connection_close`. Facade helpers (import selectively): `text`, `json`, `empty`, `not_found`, `switching_protocols`.

Default helpers set `Content-Type`, `Content-Length`, and `Connection: keep-alive`. Override with `.header` / `set_connection_close` as needed.

### Engine-injected headers (optional)

Via `ServerOptions` (default off / empty):

- `send_date: true` → `Date` (HTTP-date, UTC) if the handler did not set `Date`
- `server_header: "viltrum"` → `Server` if the handler did not set `Server`

Handler values always win. Helper: `http_date(time.utc())` after `import viltrum { http_date }`.

## Middleware

`Middleware` is `fn (next Handler) Handler`. Global: `app.use`. Route-level: `chain([...], handler)` or `Mount.use` before mount routes. Order: first registered = outermost.
