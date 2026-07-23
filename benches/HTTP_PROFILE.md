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
  → content_length_from_headers / transfer_encoding_present (string scan)
  → read body to body_start+cl
  → finish_message: msg = buf[..total].clone(); leftover = rest.clone()
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
| `finish_message` `buf[..total].clone()` | `engine.v` L396 | copy / alloc | Full wire message (headers + body) copied out of assembly buffer |
| `finish_message` leftover `buf[total..].clone()` | `engine.v` L398 | copy / alloc | Pipelined / over-read only; none on clean single-message reads |

Engine rejects TE and TE+CL conflict **before** `parse_request`, using the string scans above. Body size is also checked again after parse (`handle_conn` vs `opts.max_body_bytes`).

### Parse — `http.parse_request`

| Site | File | Cost class | Notes |
|------|------|------------|-------|
| `raw.bytestr()` | `http.v` L238 | alloc / copy | Entire message (headers **and** body) → string |
| `head.split('\r\n')`, request-line `split(' ')` | `http.v` L242–L247 | alloc | Line / token slices as new strings |
| `HeaderMap.add` → `name.to_lower()` | `http.v` L276 + L23–L28 | alloc | One map entry per header; lowercased keys |
| TE / CL re-check via `headers.get` | `http.v` L279–L287 | low | Map lookups; logic already done in engine |
| `body = raw[body_start..body_start+n].clone()` | `http.v` L300 | copy / alloc | **Second** body materialization (body already inside `finish_message` clone) |
| `params: map[string]string{}` | `http.v` L312 | alloc | Empty map every request |

For **GET `/`**: body clone is empty (`n == 0` or no CL); still pay full `raw.bytestr()`, header map, and request-line work.

For **POST small JSON**: full message string includes body bytes; body is then **cloned again** from `raw` into `Request.body`.

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

| Step | Cost class | Severity | GET `/` | POST small JSON |
|------|------------|----------|---------|-----------------|
| `accept` + `spawn` | syscall / runtime | low* | once per TCP, amortized by keep-alive | same |
| `tmp` 8 KiB alloc per message | alloc | med | every request | every request |
| `leftover.clone` (empty) | alloc | low | every request | every request |
| Grow `buf` via `<<` | alloc / copy | med | usually one `read` | often one `read` if CL fits first chunk |
| Engine CL scan (`bytestr`+`split`) | alloc / copy | **high** | yes | yes |
| Engine TE scan (duplicate string work) | alloc / copy | **high** | yes | yes |
| Engine Expect scan | alloc / copy | low / med | rare | only with `Expect: 100-continue` |
| `finish_message` full clone | copy / alloc | **high** | headers only | headers + body |
| `parse_request` full `bytestr` | alloc / copy | **high** | headers (+ empty body region) | headers + body as string |
| Header map build | alloc | med | yes | yes (+ CL / CT) |
| Body `.clone()` in parse | copy / alloc | none / **high** | none (empty) | **yes — second body copy** |
| Handler `Response.*` construction | alloc | med | small fixed headers + body bytes | same |
| `to_bytes_for_method` string build + canonicalize | alloc / copy | **high** | yes | yes |
| Wire `bytes << body` | copy | low / med | small/empty body | response body size |
| `write_tcp` | syscall | med | ≥1 write | ≥1 write |

\*Dial storms (high `c`, new connections) move accept/spawn to **high**; see `benches/RESULTS.md` scenario B.

---

## Double-work summary (the main evidence)

On a normal keep-alive request the library currently:

1. Assembles bytes in `buf`, then **clones the whole message** (`finish_message`).
2. Converts that clone to a string for parse (`raw.bytestr()`), and for POST **clones the body again** into `Request.body`.
3. Stringifies and splits header bytes **twice** in the engine (CL + TE) **before** parse does the same logical work again into `HeaderMap`.
4. Rebuilds the response as a growing string with **canonicalized** header names, then copies body into the final `[]u8` for `write`.

None of this is a correctness bug; it is repeated ownership conversion on a short-lived buffer.

---

## Recommendation

**Fix candidates** (smallest useful wins, no API change, no architecture rewrite):

1. **Body / message double materialization (highest clarity)**  
   - Today: `finish_message` clones headers+body; `parse_request` clones body again.  
   - Direction: single ownership hand-off (e.g. parse from one buffer without a second body clone, or slice body without clone where lifetime allows). Touches `finish_message` + `parse_request`.

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
