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

Helpers: `param`, `query_param`, `text`; JSON (minimal, not a full codec): `json_string` / `json_int` / `json_i64` / `json_bool` / `json_float` / `json_raw` / `json_is_null` / `json_strings`. Build helpers: `json_escape`. Forms: `form_value` (urlencoded or multipart text), `form_file`, `form_parts` / `form_parts_opts`. Multipart parse defaults: 64 parts, 1 MiB per part (raise via `FormOptions`; `0` = no extra cap). `form_parts` errors on over-limit (no silent truncate). `form_value` / `form_file` still return `none` on any parse error, including those limits — use `form_parts` when you need the reason. Still no nested multipart, no streaming-to-disk, and no `filename*` (RFC 5987; only `filename` is read). `FormPart.safe_filename()` is the last path component (`a/b.txt` → `b.txt`); empty, `.`, `..`, and embedded NUL return none.

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

## Minimal client

One request per connection (`Connection: close`). Not a general HTTP client: no redirects, cookies, pooling, or HTTP/2. No default `User-Agent`.

`Host` is derived from `addr`: IPv4/`hostname:port` as given, except `:80` / `:443` are stripped; IPv6 uses brackets (`[::1]:8080`). `127.0.0.1:<ephemeral>` is unchanged.

```v
import viltrum { client_get, client_post, fetch, client_get_tls, ClientTls }

r := client_get('127.0.0.1:8080', '/')!
// client_post(addr, '/echo', body, 'application/json')
// fetch(addr, req)
https := client_get_tls('127.0.0.1:8443', '/', ClientTls{ insecure_skip_verify: true })!
```

Cleartext `fetch` against an HTTPS port fails the handshake (and the reverse). Production TLS still belongs at the reverse proxy; `fetch_tls` is for same-process / lab HTTPS.

JSON helpers stay minimal: `json_int` is platform `int`; `json_i64` is for large IDs. `json_escape` turns other ASCII controls into `\u00XX`.

## Middleware

`Middleware` is `fn (next Handler) Handler`. Global: `app.use`. Route-level: `chain([...], handler)` or `Mount.use` before mount routes. Order: first registered = outermost.
