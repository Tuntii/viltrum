# HTTP accept / read / write hot-path profile

| | |
|--|--|
| **Version** | Viltrum v0.5.x (static inspection of this tree) |
| **Date** | 2026-07-23 |
| **Scope** | Cleartext HTTP/1.1 keep-alive: **GET `/`** (empty body) and **POST** with small JSON body + `Content-Length` |
| **Method** | Static code inspection of `engine/engine.v` and `http/http.v`. Optional local oha timing is out of band (`benches/RESULTS.md`); this note is **not** a `perf`/flamegraph lab claim. |
| **Out of scope** | TLS, HTTP/2, upgrade/WS after hijack, TE/chunked (rejected), max_conns 503 path |

Handler path under study:

```
listener.accept
  → spawn handle_conn
    → read_message          (engine/engine.v)
    → http.parse_request    (http/http.v)
    → handler(req)
    → apply_response_defaults / Connection
    → Response.to_bytes_for_method
    → write_tcp
```

---

## Path walk (real functions)

### Accept + conn loop — `listen_and_serve_full` / `handle_conn`

- `net.listen_tcp` then `listener.accept()` (syscall per new TCP).
- Each accepted socket: `spawn handle_conn(...)` (one goroutine per connection).
- Keep-alive loop: idle timeout between requests (`opts.idle_timeout`), then request timeouts.
- Success path after parse: `handler(req)` → `http.should_close` → optional `Connection` header → `apply_response_defaults` → `write_tcp(mut conn, resp.to_bytes_for_method(req.method))`.
- No intermediate buffering on the write side beyond the serialized `[]u8` from `to_bytes_for_method`.

### Read + frame — `read_message` / `finish_message`

```text
leftover.clone() → grow buf via conn.read(tmp) → find \r\n\r\n
  → content_length_from_headers / transfer_encoding_present (byte scan)
  → read body to body_start+cl
  → finish_message: exact → return buf; over-read → leftover=rest.clone(), msg=buf[..total] view
```

| Site | File | Cost class | Notes |
|------|------|------------|-------|
| `leftover.clone()` into `buf` | `engine.v` `read_message` L314 | copy / alloc | Every message; empty clone when no pipeline leftover |
| `[]u8{len: opts.read_chunk_size}` (`tmp`, default 8 KiB) | `read_message` L317 | alloc | Fresh scratch buffer **per message**, not reused across keep-alive requests |
| `buf << tmp[..n]` | `read_message` L366, L389 | alloc / copy | Dynamic growth of the assembly buffer (may reallocate) |
| `index_of_double_crlf` | `engine.v` L403 | none (CPU scan) | Byte walk, no heap |
| `content_length_from_headers` | `engine.v` L416 | alloc / copy | `header_bytes.bytestr()` + `split('\r\n')` + `to_lower()` on each line |
| `transfer_encoding_present` | `engine.v` L430 | alloc / copy | **Second** full header `bytestr` + `split` + `to_lower` on same bytes |
| `expects_100_continue` | `engine.v` L443 | alloc / copy | **Third** header stringification when `cl > 0` (POST with Expect) |
| `finish_message` hand-off / leftover | `engine.v` `finish_message` | none / copy | Exact-length: return assembly `buf` (no full-message clone). Over-read: leftover tail `.clone()` only; message is length-limited view (PR3) |

Engine rejects TE and TE+CL conflict **before** `parse_request`, using the string scans above. Body size is also checked again after parse (`handle_conn` vs `opts.max_body_bytes`).

### Parse — `http.parse_request`

| Site | File | Cost class | Notes |
|------|------|------------|-------|
| Double-CRLF + line walk on `[]u8` | `http.v` `parse_request` | none / CPU | No full-message `bytestr` (PR2) |
| Request-line / header field `bytestr` of slices only | `http.v` | alloc | Method, target, version, each name/value — not body |
| `HeaderMap.add` → `name.to_lower()` | `http.v` | alloc | One map entry per header; lowercased keys |
| TE / CL re-check via `headers.get` | `http.v` | low | Map lookups; logic already done in engine |
| `body = raw[body_start..body_start+n]` (slice) | `http.v` | none | Shares message buffer; no second body materialization (PR3) |
| `params: map[string]string{}` | `http.v` | alloc | Empty map every request |

For **GET `/`**: body clone is empty (`n == 0` or no CL); pay per-field strings + header map, not a full-message string.

For **POST small JSON**: body stays binary until the explicit clone into `Request.body` (still a second materialization vs engine — PR3).

### Handler (typical GET / POST)

Out of library control, but common costs:

- `Response.text` / `Response.json`: `body.bytes()`, `HeaderMap.new()`, three `headers.set` (each `to_lower` key).
- JSON helpers (`Request.json_string` etc.) call `r.text()` → another `body.bytestr()` if used.

### Serialize + write — `to_bytes_for_method` / `write_tcp`

| Site | File | Cost class | Notes |
|------|------|------------|-------|
| Status line + per-header `out +=` | `http.v` L210–L214 | alloc / copy | Growing string; one concat per header |
| `canonicalize_header_name` | `http.v` L471–L483 | alloc | Per header: `split('-')`, case folds, `join` |
| `out.bytes()` | `http.v` L215 | alloc / copy | Header block → `[]u8` |
| `bytes << r.body` | `http.v` L217 | copy | Body appended into wire buffer (extra body copy on POST responses) |
| `write_tcp` / `conn.write` | `engine.v` L284–L292 | syscall | Full write loop; may split if short write |

`apply_response_defaults` is cheap when `send_date` is off and `server_header` is empty (bench default).

---

## Hot-path table (severity for GET `/` and POST small JSON)

Severity = impact on **steady keep-alive** request cost in this codebase (not absolute wall time).

Note: rows for per-message `tmp` and engine CL/TE string scans describe the pre-#9 path; both were addressed in **Decision** below (tmp reuse + `header_value_ci`).

| Step | Cost class | Severity | GET `/` | POST small JSON |
|------|------------|----------|---------|-----------------|
| `accept` + `spawn` | syscall / runtime | low* | once per TCP, amortized by keep-alive | same |
| `tmp` 8 KiB alloc per message | alloc | med | every request | every request |
| `leftover.clone` (empty) | alloc | low | every request | every request |
| Grow `buf` via `<<` | alloc / copy | med | usually one `read` | often one `read` if CL fits first chunk |
| Engine CL scan (`bytestr`+`split`) | alloc / copy | **high** | yes | yes |
| Engine TE scan (duplicate string work) | alloc / copy | **high** | yes | yes |
| Engine Expect scan | alloc / copy | low / med | rare | only with `Expect: 100-continue` |
| `finish_message` hand-off | none / copy | low | exact-length: no clone | same; leftover only if pipelined |
| `parse_request` full `bytestr` | alloc / copy | — | removed (PR2) | removed (PR2) |
| Header map build | alloc | med | yes | yes (+ CL / CT) |
| Body slice in parse | none | none | empty body | shares message buffer (PR3) |
| Handler `Response.*` construction | alloc | med | small fixed headers + body bytes | same |
| `to_bytes_for_method` string build + canonicalize | alloc / copy | **high** | yes | yes |
| Wire `bytes << body` | copy | low / med | small/empty body | response body size |
| `write_tcp` | syscall | med | ≥1 write | ≥1 write |

\*Dial storms (high `c`, new connections) move accept/spawn to **high**; see `benches/RESULTS.md` scenario B.

---

## Double-work summary (the main evidence)

On a normal keep-alive request the library **used to**:

1. Assemble bytes in `buf`, then **clone the whole message** (`finish_message`).
2. Convert that clone to a string for parse (`raw.bytestr()`), and for POST **clone the body again** into `Request.body`.
3. Stringify and split header bytes **twice** in the engine (CL + TE) **before** parse does the same logical work again into `HeaderMap`.
4. Rebuild the response as a growing string with **canonicalized** header names, then copy body into the final `[]u8` for `write`.

**Status:** (2) full-message `bytestr` removed in PR2; (1)+(body half of 2) single ownership in PR3; engine CL/TE string scans addressed in #9. Remaining: (4) response serialize (PR4), conn-local assembly reuse (PR5).

---

## Recommendation

**Fix candidates** (smallest useful wins, no API change, no architecture rewrite):

1. **Body / message double materialization** — **done (PR3 / #19)**  
   - Was: `finish_message` full clone + `parse_request` body clone.  
   - Now: exact-length hand-off; body is a slice of the message buffer.

2. **Engine header pre-scan without full stringification (high, localized)**  
   - Today: `content_length_from_headers` and `transfer_encoding_present` each do `bytestr` + `split` + per-line `to_lower`.  
   - Direction: byte-level case-insensitive search for `Content-Length` / `Transfer-Encoding` (and Expect if needed) without building a full string twice. Keeps reject-before-body behavior.

3. **Response serialize path (med–high)**  
   - Today: `to_bytes_for_method` uses repeated `out +=` and `canonicalize_header_name` per header.  
   - Direction: pre-size / builder, or write known headers with fixed casing when keys are already lowercased in `HeaderMap` (canonicalize once or store display form). Avoid an extra body copy if headers and body can be written in two `write_tcp` calls **only if** that stays simple and correct (optional; measure).

4. **Reuse `tmp` (and optionally assembly buf) on the connection (med, easy)**  
   - Allocate `tmp` once in `handle_conn` and pass into `read_message` instead of `[]u8{len: read_chunk_size}` every message.

**Not recommended as #9 work:** reactor/io_uring, pooled `HeaderMap` public API, zero-copy request types, TE/chunked support, chasing a 100k req/s claim.

**Default if only one change ships:** (1) or (2). Both are obvious waste in this tree with named call sites; neither requires public API churn.

---

## Relation to published benches

`benches/RESULTS.md` already shows this laptop sustains roughly **60–85k req/s** GET `/` (oha, cleartext, logging off). This profile explains **where CPU/alloc work sits** inside that number; it does not re-benchmark. Any micro-opt that lands should only update RESULTS if sustained change is clearly material (plan bar: roughly &gt;10%).

---

## Decision

| | |
|--|--|
| **Date** | 2026-07-29 (updated) |
| **Path** | Fix (micro-opts #2, #4, then #1 body ownership) |
| **Not done** | Response serialize rewrite (#3), public API, reactor, HTTP/2 |
| **Follow-up** | Full hot-path epic **v0.8** / [#16](https://github.com/Tuntii/viltrum/issues/16) (PR4–PR7). Baseline vs Axum: `benches/compare/` |

**Landed:**

1. **Reuse `tmp` across keep-alive requests** — allocate `[]u8{len: read_chunk_size}` once in `handle_conn` and pass into `read_message` (no per-message scratch alloc).
2. **Engine CL/TE pre-scan without full stringification** — `content_length_from_headers` / `transfer_encoding_present` use byte-level case-insensitive field scan (`header_value_ci`) instead of `bytestr` + `split` + `to_lower` twice. Reject-before-body and TE+CL conflict behavior unchanged. `expects_100_continue` left as string path (out of scope).
3. **Single message ownership (PR3 / #19)** — `finish_message` hands off the assembly buffer on exact-length reads (no full-message clone); over-read clones only the leftover tail. `parse_request` takes `Request.body` as a slice of that buffer (no second body `.clone()`). One body ownership path for the engine → parse hand-off.

**Tests:** `v test engine/` (incl. finish_message unit tests) and `v test http/` — green.
