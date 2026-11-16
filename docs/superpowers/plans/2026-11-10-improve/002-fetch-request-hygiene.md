# Plan 002: A fetch cannot carry framing headers, and a deferred request cannot be answered twice

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat acb27f3..HEAD -- http1/ctx.v http1/ctx_test.v http1/reply_test.v engine/worker_linux.c.v docs/client.md docs/request-response.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. (Plan 001 does not touch these files.)

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (run after plan 001 only to keep the branch history linear)
- **Category**: bug / security
- **Planned at**: commit `acb27f3`, 2026-11-10 (branch `feat/http-client`)

## Why this matters

Three small holes around `c.fetch` / `c.after`:

1. `c.fetch_header(name, value)` accepts `Host`, `Content-Length`,
   `Transfer-Encoding`, `Connection` and friends. The engine writes its own `Host` and
   `Content-Length`, so a handler that forwards a client's headers (the documented
   "proxy on top of fetch" use) can send an upstream request framed two ways on a
   pooled connection shared with other users.
2. A handler that calls `c.fetch(...)` or `c.after(...)` and then writes a response
   (`c.text(...)`) puts **two** responses on an HTTP/1.1 connection for one request;
   every later pipelined response is then matched to the wrong request. `c.file` and
   `c.stream` already refuse this; `respond` does not.
3. A fetch started while the once-a-second sweep runs is not connected until the next
   loop wake-up, up to a second later.

## Current state

`http1/ctx.v:408-416`:

```v
// fetch_header adds a header to the request fetch sends; at most 8. Host and
// Content-Length are written by the engine. A field that is not a valid header is
// dropped.
pub fn (mut c Ctx) fetch_header(name string, value string) {
	if c.fetching && c.nfetch_hdrs < c.fetch_hdrs.len && valid_name(name) && valid_value(value) {
		c.fetch_hdrs[c.nfetch_hdrs] = HeaderPair{name, value}
		c.nfetch_hdrs++
	}
}
```

`http1/ctx.v:577-585` (`respond`, called by `text`, `json`, `bytes`, `text_int`,
`status`, `html`, `redirect`):

```v
// respond returns false when a response was already sent.
fn (mut c Ctx) respond(status int, content_type string, body voidptr, n int) bool {
	if c.responded {
		$if viltrum_debug ? {
			panic('viltrum: second response for one request')
		}
		return false
	}
	c.responded = true
```

The same guard elsewhere already includes `deferred`, e.g. `http1/ctx.v:359`
(`after`) and `:383` (`fetch`): `if c.responded || c.deferred {`, and `http1/file.v:52`.

`c.deferred` is set by `after` (when `ms > 0`) and by `fetch`. It is cleared by
`Ctx.begin` (`http1/ctx.v:114-120`), which the engine calls before it runs the
deferred callback, so the callback itself can still respond.

`http1/bytes.v:83-95` has the comparison to use:

```v
// eq_ci compares s with an ASCII-lowercase literal, ignoring the case of s.
pub fn eq_ci(s string, lower_lit string) bool {
```

`engine/worker_linux.c.v`, in the event loop (lines 134-143) and `sweep` (880-909):

```v
		l.fire()
		if l.w.ready.len > 0 || l.w.fails.len > 0 {
			l.kick() // only with fetches to start: the call alone cost 32 Ir a turn
		}
		if l.now - l.last_sweep >= 1000 {
			l.sweep()
			l.last_sweep = l.now
		}
```

```v
	l.sweep_peers()
	for i in 0 .. l.conns.len {
		...
		// a waiting connection is answered by its timer, not timed out
		if c.waiting || c.h2_waits() || l.now <= c.deadline_ms {
			continue
		}
		l.close(mut c)
	}
}
```

`l.w.ready` holds upstream connections to connect or write on this turn; `l.w.fails`
holds fetches to answer with an error at once; `kick()` handles both. Inside `sweep`,
the loop over `l.conns` can run handlers (a stream that ends lets a pipelined request
run), and those can call `fetch` after `sweep_peers` already kicked.

Existing test to extend, `http1/reply_test.v:117-127`:

```v
fn test_write_fetch() {
	mut c := Ctx.new()
	c.begin(view(c.buf, 0, 0))
	c.fetch(Upstream{ id: 0 }, .post, '/users?x=1', unsafe { nil }, 7)
	c.fetch_body('{"a":1}'.bytes())
	c.fetch_header('Content-Type', 'application/json')
	c.fetch_header('Bad', 'a\r\nInjected: 1') // dropped
	assert c.fetch_valid()
	mut out := []u8{}
	c.write_fetch(mut out, 'api:9000')
	assert out.bytestr() == 'POST /users?x=1 HTTP/1.1\r\nHost: api:9000\r\nContent-Length: 7\r\nContent-Type: application/json\r\n\r\n{"a":1}'
```

Test helpers in `http1/ctx_test.v`: `test_ctx(raw string) !Ctx` builds a `Ctx` for a
raw request, `out_of(c)` is the response bytes written so far (see
`test_invalid_headers_are_dropped`, line 131).

Conventions:

- **Zero allocation on the request path.** `bash scripts/hotpath_lint.sh` greps
  `http1/ctx.v` and `engine/worker_linux.c.v` for `${`, `.str()`, `.clone()`,
  `.to_lower(`, `.trim`, `.split(`, slices `a[x..y]`. Do not use them in non-test
  code. In particular: compare names with `eq_ci`, never `name.to_lower()`.
- `respond` is on the hottest path of the framework. CI gates pull requests on
  instructions per request (more than +1% on a scenario fails). One extra field
  compare is fine; a function call or a loop there is not.
- Misuse is answered quietly in release builds and panics under `-d viltrum_debug`
  (see the `$if viltrum_debug ?` blocks above). Keep that pattern.
- **Edit `.v` files with a file-editing tool, never shell heredocs/`sed`/Python**:
  shells turn `\r\n` escapes inside V string literals into real control characters.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Link the module (once) | `bash scripts/install.sh` | prints `linked: ...` |
| Format | `v fmt -w <changed files>` then `v fmt -verify .` | exit 0 |
| Unit tests (any OS) | `v test http1/` | all pass |
| Whole suite | `v test http1/ http2/ jsonenc/ router/ engine/ tests/` | all pass |
| Debug build tests | `v -d viltrum_debug test router/ engine/ tests/` | all pass |
| Hot-path lint | `bash scripts/hotpath_lint.sh` | `hot path clean` |

`engine/*_linux_test.v` run only on Linux. If you are not on Linux, run the portable
commands, and set the status to `BLOCKED (Linux-only tests not run)` instead of DONE.

## Scope

**In scope**:

- `http1/ctx.v`
- `http1/reply_test.v` (extend `test_write_fetch`)
- `http1/ctx_test.v` (one new test)
- `engine/worker_linux.c.v` (two lines at the end of `sweep`)
- `docs/client.md`, `docs/request-response.md` (one sentence each)

**Out of scope**:

- `engine/client.v`, `engine/client_linux.c.v`, `http1/reply.v` — plan 001.
- `engine/h2.v` — plan 003.
- `fetch_valid` and the request target. Dot-segments in a forwarded `c.path()` are
  handled as a documentation note in plan 005, not by changing validation.
- `middleware.v`.

## Git workflow

- Branch from `feat/http-client` (or from plan 001's branch if it is not merged yet):
  `advisor/002-fetch-request-hygiene`.
- Conventional Commits, e.g. `fix(client): drop framing headers passed to fetch_header`,
  `fix(http1): refuse a response written after after() or fetch()`.
- Do NOT push or open a PR unless told to. Do not change git config.

## Steps

### Step 1: Failing tests first

a) In `http1/reply_test.v`, `test_write_fetch`, add right after the
`c.fetch_header('Bad', ...)` line:

```v
	// the engine frames the request: these names are not the handler's to set
	for name in ['Host', 'content-length', 'Transfer-Encoding', 'CONNECTION', 'Keep-Alive',
		'Proxy-Connection', 'TE', 'Upgrade', 'Expect'] {
		c.fetch_header(name, 'x')
	}
```

The existing `assert out.bytestr() == '...'` line right below must stay unchanged: it
now also proves none of the nine was written.

b) In `http1/ctx_test.v`, add:

```v
fn late_cb(mut c Ctx, arg u64) {
	c.text(200, 'late')
}

// A request handed to after() or fetch() is answered by its callback alone: a
// response written meanwhile would be a second one on the wire.
fn test_no_response_once_deferred() {
	mut c := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	c.after(50, late_cb, 0)
	c.text(200, 'early')
	c.json(200, Msg{ message: 'early' })
	assert out_of(c) == ''
	assert c.deferred && !c.responded
	mut d := test_ctx('GET / HTTP/1.1\r\nHost: h\r\n\r\n')!
	d.fetch(Upstream{ id: 0 }, .get, '/x', late_cb, 0)
	d.text(200, 'early')
	assert out_of(d) == ''
}
```

(`Msg` is the struct at the top of `ctx_test.v`. If `c.json`'s signature differs,
drop that one line.)

**Verify**: `v test http1/reply_test.v http1/ctx_test.v` → `test_write_fetch` and
`test_no_response_once_deferred` FAIL; everything else passes.

### Step 2: Drop reserved names in `fetch_header`

In `http1/ctx.v`, change `fetch_header` and add a helper below it:

```v
// fetch_header adds a header to the request fetch sends; at most 8. The engine
// frames the request, so Host, Content-Length, Transfer-Encoding and the
// connection's own fields (fetch_reserved) are dropped, as is a field that is not a
// valid header.
pub fn (mut c Ctx) fetch_header(name string, value string) {
	if c.fetching && c.nfetch_hdrs < c.fetch_hdrs.len && valid_name(name) && valid_value(value)
		&& !fetch_reserved(name) {
		c.fetch_hdrs[c.nfetch_hdrs] = HeaderPair{name, value}
		c.nfetch_hdrs++
	}
}

// fetch_reserved is whether name is a field the client writes itself or that speaks
// for the connection, not the request: forwarded from a caller, it would frame the
// request a second way on a connection other requests share.
fn fetch_reserved(name string) bool {
	return match name.len {
		2 { eq_ci(name, 'te') }
		4 { eq_ci(name, 'host') }
		6 { eq_ci(name, 'expect') }
		7 { eq_ci(name, 'upgrade') }
		10 { eq_ci(name, 'connection') || eq_ci(name, 'keep-alive') }
		14 { eq_ci(name, 'content-length') }
		16 { eq_ci(name, 'proxy-connection') }
		17 { eq_ci(name, 'transfer-encoding') }
		else { false }
	}
}
```

**Verify**: `v test http1/reply_test.v` → `test_write_fetch` passes.

### Step 3: `respond` refuses once the request is deferred

In `http1/ctx.v`, `respond`: change `if c.responded {` to
`if c.responded || c.deferred {` and the comment above it to
`// respond returns false when a response was already sent, or is deferred (after, fetch).`
Leave the `$if viltrum_debug ?` panic as it is.

**Verify**: `v test http1/` → all pass, including `test_no_response_once_deferred`.

### Step 4: Start fetches made during the sweep

In `engine/worker_linux.c.v`, at the very end of `fn (mut l Loop) sweep()` (after the
`for i in 0 .. l.conns.len { ... }` loop closes, before the function's closing brace):

```v
	// a stream ended above may have let a pipelined request run and fetch
	if l.w.ready.len > 0 || l.w.fails.len > 0 {
		l.kick()
	}
```

There is no cheap deterministic test for this path (it needs a request pipelined
behind an SSE stream that ends inside a heartbeat); it is verified by the suite still
passing.

**Verify**: `grep -n "l.kick()" engine/worker_linux.c.v` → two matches in this file
(the loop's and the new one).

### Step 5: Documentation

- `docs/client.md`, in the bullet that starts "Before the handler returns,
  `c.fetch_body(data)`": after "`c.fetch_header(name, value)` adds a header, at most 8."
  add: "`Host`, `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`,
  `Proxy-Connection`, `TE`, `Upgrade` and `Expect` are the engine's to write and are
  dropped."
- `docs/client.md`, in the paragraph that starts "As with `after`, the incoming
  request is gone": append "A response written in the handler after `fetch` is dropped:
  the callback answers the request."
- `docs/request-response.md`: find the paragraph that documents `c.after`
  (`grep -n "after" docs/request-response.md`) and add the same sentence adapted:
  "A response written in the handler after `after` is dropped: the callback answers the
  request." If no paragraph documents `after`, skip this bullet and say so in your
  report.

**Verify**: `grep -n "Proxy-Connection" docs/client.md` → one match.

### Step 6: Format, lint, full suite

**Verify**:
- `v fmt -w http1/ctx.v http1/ctx_test.v http1/reply_test.v engine/worker_linux.c.v && v fmt -verify .` → exit 0
- `bash scripts/hotpath_lint.sh` → `hot path clean`
- `v test http1/ http2/ jsonenc/ router/ engine/ tests/` → all pass
- `v -d viltrum_debug test router/ engine/ tests/` → all pass

## Test plan

- `test_write_fetch` (extended, `http1/reply_test.v`): nine reserved names in mixed
  case are dropped; the exact expected request bytes are unchanged.
- `test_no_response_once_deferred` (new, `http1/ctx_test.v`): `text`/`json` after
  `after()` and after `fetch()` write nothing. Model: `test_invalid_headers_are_dropped`
  in the same file.
- Existing zero-allocation tests (`test_handler_path_allocates_nothing` in
  `http1/ctx_test.v`, `test_fetch_allocates_nothing` in
  `engine/client_linux_test.v`) must still pass.

## Done criteria

- [ ] `grep -n "fn fetch_reserved" http1/ctx.v` → one match
- [ ] `grep -n "if c.responded || c.deferred" http1/ctx.v` → three matches (`after`, `fetch`, `respond`)
- [ ] `v test http1/` exits 0
- [ ] `v test http1/ http2/ jsonenc/ router/ engine/ tests/` exits 0 (on Linux this includes the socket tests)
- [ ] `v -d viltrum_debug test router/ engine/ tests/` exits 0
- [ ] `bash scripts/hotpath_lint.sh` prints `hot path clean`; `v fmt -verify .` exits 0
- [ ] `git status --short` lists only in-scope files (plus `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The code at the locations in "Current state" does not match the excerpts.
- After Step 3, any existing test fails. That means some code path in the repo
  legitimately responds while `deferred` is set (for example an example app, the
  `recover` middleware, or the HTTP/2 path). Do not weaken the guard to make it pass:
  report which test and which call.
- `v -d viltrum_debug test ...` panics with "second response for one request" in a
  test you did not write: same as above, report it.
- The `match name.len { ... }` form does not compile on V 0.5.2: replace it with an
  `if`/`else if` chain on `name.len` with the same comparisons; if that also fails,
  stop.

## Maintenance notes

- `fetch_reserved` is a fixed list. When HTTPS upstreams or request-body streaming
  land (Phase 9b and later), revisit `Expect` and `Upgrade`.
- The perf gate (`.github/workflows/perf.yml`) will measure Step 3 on the pull
  request: expect about one instruction per request. If it reports more than 1% on a
  scenario, the compiler did something unexpected — look before adding `perf-ok`.
- Over HTTP/2 a response written after `fetch`/`after` was already dropped silently
  (`engine/h2.v`, `h2_resume` clears the output buffer); Step 3 makes HTTP/1.1 match.
- Reviewer: confirm no handler in `examples/` or `benches/httparena/main.v` writes a
  response after `after()`/`fetch()` (`grep -n "\.after(\|\.fetch(" examples benches -r`).
