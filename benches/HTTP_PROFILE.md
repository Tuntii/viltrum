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
| Conn-local `assem` (truncate / seed) | `engine.v` `read_message` | none / copy | Empty leftover: `assem.len=0` (cap kept). Pipelined leftover: seed into assem (cap reused) |
| Conn-local `tmp` (8 KiB) | `handle_conn` → `read_message` | none | One read scratch per Conn (not per message) |
| `assem << tmp[..n]` | `read_message` | alloc / copy | Grows only when cap exceeded; capacity retained across keep-alive (PR5) |
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
| Pre-sized `[]u8` into conn-local scratch | `http.v` `to_bytes_for_method_into` | none / alloc | Reuses `write_buf` cap on keep-alive (PR5); grows only if need > cap |
| Known-header casing cache | `http.v` `append_wire_header_name` | none | Hot names (`content-type`, `connection`, …) fixed match; no split/join |
| `canonicalize_header_name` | `http.v` | alloc | Only **unknown** custom headers |
| Body append into wire buffer | `http.v` | copy | Response body once into the same `[]u8` |
| `write_all` / `conn.write` | `engine.v` | syscall | Full write loop; may split if short write |

`apply_response_defaults` is cheap when `send_date` is off and `server_header` is empty (bench default).

---

## Hot-path table (severity for GET `/` and POST small JSON)

Severity = impact on **steady keep-alive** request cost in this codebase (not absolute wall time).

Note: rows for per-message `tmp` and engine CL/TE string scans describe the pre-#9 path; both were addressed in **Decision** below (tmp reuse + `header_value_ci`).

| Step | Cost class | Severity | GET `/` | POST small JSON |
|------|------------|----------|---------|-----------------|
| `accept` + `spawn` | syscall / runtime | low* | once per TCP, amortized by keep-alive | same |
| Conn-local `tmp` / `assem` / `write_buf` | none | low | reused (PR5) | reused (PR5) |
| Seed leftover into assem (pipeline only) | copy | low | rare | rare |
| Grow `assem` via `<<` | alloc / copy | low / med | only when cap exceeded | same |
| Engine CL scan (`bytestr`+`split`) | alloc / copy | **high** | yes | yes |
| Engine TE scan (duplicate string work) | alloc / copy | **high** | yes | yes |
| Engine Expect scan | alloc / copy | low / med | rare | only with `Expect: 100-continue` |
| `finish_message` hand-off | none / copy | low | exact-length: no clone | same; leftover only if pipelined |
| `parse_request` full `bytestr` | alloc / copy | — | removed (PR2) | removed (PR2) |
| Header map build | alloc | med | yes | yes (+ CL / CT) |
| Body slice in parse | none | none | empty body | shares message buffer (PR3) |
| Handler `Response.*` construction | alloc | med | small fixed headers + body bytes | same |
| `to_bytes_for_method` `[]u8` builder + casing cache | alloc / copy | med | one buffer (PR4) | same |
| Wire body into same buffer | copy | low / med | small body | response body size |
| `write_tcp` | syscall | med | ≥1 write | ≥1 write |

\*Dial storms (high `c`, new connections) move accept/spawn to **high**; see `benches/RESULTS.md` scenario B.

---

## Double-work summary (the main evidence)

On a normal keep-alive request the library **used to**:

1. Assemble bytes in `buf`, then **clone the whole message** (`finish_message`).
2. Convert that clone to a string for parse (`raw.bytestr()`), and for POST **clone the body again** into `Request.body`.
3. Stringify and split header bytes **twice** in the engine (CL + TE) **before** parse does the same logical work again into `HeaderMap`.
4. Rebuild the response as a growing string with **canonicalized** header names, then copy body into the final `[]u8` for `write`.

**Status:** PR2–PR7 complete. Hot-path double work addressed; multi-accept measured (default single); RESULTS re-locked 2026-08-05 (E ~98k, peer ~2×). League bar not met — remaining cost is largely runtime/OS, not another message clone.

---

## Recommendation

**Fix candidates** (smallest useful wins, no API change, no architecture rewrite):

1. **Body / message double materialization** — **done (PR3 / #19)**  
   - Was: `finish_message` full clone + `parse_request` body clone.  
   - Now: exact-length hand-off; body is a slice of the message buffer.

2. **Engine header pre-scan without full stringification (high, localized)**  
   - Today: `content_length_from_headers` and `transfer_encoding_present` each do `bytestr` + `split` + per-line `to_lower`.  
   - Direction: byte-level case-insensitive search for `Content-Length` / `Transfer-Encoding` (and Expect if needed) without building a full string twice. Keeps reject-before-body behavior.

3. **Response serialize path** — **done (PR4 / #20)**  
   - Was: growing string `+=` + per-header `canonicalize_header_name` + full `out.bytes()`.  
   - Now: pre-sized `[]u8` builder; known-header casing cache; canonicalize only for custom names.

4. **Reuse `tmp` / assembly / write scratch on the connection** — **done (PR5 / #21)**  
   - Was: empty `leftover.clone()` + fresh response `[]u8` each request; `tmp` already per-conn.  
   - Now: conn-local `assem` + `write_buf` across keep-alive; `to_bytes_for_method_into` reuses write capacity.

**Not recommended as #9 work:** reactor/io_uring, pooled `HeaderMap` public API, zero-copy request types, TE/chunked support, chasing a 100k req/s claim.

**Default if only one change ships:** (1) or (2). Both are obvious waste in this tree with named call sites; neither requires public API churn.

---

## Relation to published benches

`benches/RESULTS.md` already shows this laptop sustains roughly **60–85k req/s** GET `/` (oha, cleartext, logging off). This profile explains **where CPU/alloc work sits** inside that number; it does not re-benchmark. Any micro-opt that lands should only update RESULTS if sustained change is clearly material (plan bar: roughly &gt;10%).

---

## Decision

| | |
|--|--|
| **Date** | 2026-08-05 (PR7 closeout) |
| **Path** | Fix (PR2–PR5 alloc/serialize; PR6 multi-accept measure only) |
| **Not done** | League bar (E ≥150k or ≥0.75× peer); reactor / HTTP/2; wrapping foreign stacks |
| **Follow-up** | Epic **v0.8** / [#16](https://github.com/Tuntii/viltrum/issues/16) **closed** after PR7 docs. Further gains need runtime-level work, not another HTTP clone. |

**Landed:**

1. **Reuse `tmp` across keep-alive requests** — allocate `[]u8{len: read_chunk_size}` once in `handle_conn` and pass into `read_message` (no per-message scratch alloc).
2. **Engine CL/TE pre-scan without full stringification** — `content_length_from_headers` / `transfer_encoding_present` use byte-level case-insensitive field scan (`header_value_ci`) instead of `bytestr` + `split` + `to_lower` twice. Reject-before-body and TE+CL conflict behavior unchanged. `expects_100_continue` left as string path (out of scope).
3. **Single message ownership (PR3 / #19)** — `finish_message` hands off the assembly buffer on exact-length reads (no full-message clone); over-read clones only the leftover tail. `parse_request` takes `Request.body` as a slice of that buffer (no second body `.clone()`). One body ownership path for the engine → parse hand-off.
4. **Response `[]u8` builder + header casing cache (PR4 / #20)** — `to_bytes_for_method` writes a pre-sized byte buffer (no growing string + `out.bytes()`). Known headers use fixed wire casing; `canonicalize_header_name` only for custom fields. HEAD check is case-insensitive without full `to_upper`.
5. **Conn-local assembly + write scratch (PR5 / #21)** — `read_message` assembles into conn-local `assem` (truncate in place; seed from leftover when pipelined). Hot-path write uses `to_bytes_for_method_into` into conn-local `write_buf`. Capacity retained across keep-alive requests after handler + write complete.
6. **Multi-accept / `SO_REUSEPORT` (PR6 / #22)** — optional `accept_workers` (default **1**). Linux multi-listener helps dial storms; keep-alive E/F gain is small/noisy. **Default stays single listener.** See [compare/REUSEPORT.md](./compare/REUSEPORT.md).
7. **Honest closeout (PR7 / #23)** — RESULTS + compare table re-locked 2026-08-05: E ~**98k** / F ~**91k** vs Axum ~191k / ~225k. League bar **not** met; remaining gap attributed mainly to V runtime + per-conn spawn + OS path, not missing buffer clones on the HTTP hot path.

**Tests:** `v test http/ router/ engine/ ws/` — green (incl. seed/recycle + into-builder reuse + multi-worker smoke).

### Remaining cost (post-PR6, for the next person)

| Layer | Still pays | Why it is not “one more PR2-style fix” |
|-------|------------|----------------------------------------|
| Accept + `spawn handle_conn` | syscall + runtime | One goroutine per TCP conn; multi-listener (PR6) helps dial storms only |
| Per-request string fields | method/target/header `bytestr` | Needed for `HeaderMap` / handler API unless public types change |
| Handler `Response` construction | map + body bytes | App-owned; library defaults stay cheap when Date/Server off |
| OS write path | ≥1 `write` per response | Already single buffer (PR4/PR5); two-write vectored optional later |
| V GC / scheduler | global | Peer (Tokio) is a different concurrency model |

Do **not** claim multi-hundred-k RPS without re-measuring; do **not** re-open the double-clone story without a new profile.
