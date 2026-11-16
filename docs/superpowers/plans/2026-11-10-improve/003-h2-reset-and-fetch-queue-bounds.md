# Plan 003: Resetting an HTTP/2 stream does not free its deferred work from the stream limit, and the fetch queue is bounded in bytes

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat acb27f3..HEAD -- engine/h2.v engine/h2_test.v engine/client.v docs/client.md docs/http2.md`
> Plan 001 adds one field and one line to `engine/client.v` (`Peer.interims`); that
> change is expected. Any other difference in these files: compare the "Current
> state" excerpts against the live code and treat a mismatch as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (touches HTTP/2 stream accounting)
- **Depends on**: plans/001-client-reply-path-robustness.md (same file `engine/client.v`; apply after it to avoid conflicts)
- **Category**: security
- **Planned at**: commit `acb27f3`, 2026-11-10 (branch `feat/http-client`)

## Why this matters

**Part A.** An HTTP/2 client may open at most 128 concurrent streams per connection
(`h2_max_streams`). A handler can defer its response with `c.after(ms, ...)` (a timer)
or `c.fetch(...)` (a request to an upstream service). When the client then resets the
stream (`RST_STREAM`), the stream's slot is freed at once, but the timer or the
upstream request it started lives on until it is due or answered. So one connection
can send `HEADERS` + `RST_STREAM` pairs in a loop — about 30 bytes each — and every
pair becomes a full upstream request or a timer-heap entry, with the stream limit never
reached. All upstream connections and queue slots of the worker stay full and every
legitimate fetch answers `.busy`. This is the "rapid reset" pattern applied to deferred
work.

After this plan, a stream that is reset while it waits keeps counting against the
128-stream limit until its timer fires or its fetch is answered.

**Part B.** Fetches that wait for a free upstream connection are queued as bytes in
`Pool.q`, limited only by count (`max_queue`, default 1024) — each can carry a request
body of up to `max_body_bytes` (1 MiB default), so about 1 GiB per worker per upstream.
The buffer's capacity is never given back. After this plan the queue is also bounded
by bytes and gives a large buffer back once it is empty.

## Current state

### Part A — `engine/h2.v`

Constants (line 16) and counters on `H2Conn` (lines 80-125):

```v
const h2_max_streams = 128 // SETTINGS_MAX_CONCURRENT_STREAMS we announce
...
struct H2Conn {
mut:
	...
	streams    []H2Stream
	open       int // streams in use
	sending    int // streams with output held back
	waiting    int // streams whose response is deferred
	streaming  int // streams whose body is still being written (Ctx.stream)
	held       i64 // response bytes held back in slots
	files      int // file answers held back
	pump_next  int // the slot h2_pump starts its next pass at
	flood      int
```

`h2_open` resets the counters for a pooled connection object (lines 150-163):

```v
	h.hstream = 0
	h.open = 0
	h.sending = 0
	h.waiting = 0
	h.streaming = 0
	h.held = 0
	h.files = 0
	h.pump_next = 0
	h.flood = 0
```

`release` frees a stream slot (lines 370-410):

```v
// release frees slot i: its file closed, its body's bytes out of buffered.
fn (mut h H2Conn) release(i int) {
	mut s := &h.streams[i]
	if s.id == 0 {
		return
	}
	...
	if s.waiting {
		h.waiting-- // its timer finds the stream gone and is dropped
		s.waiting = false
	}
	...
	s.id = 0
	h.open--
```

The limit check when a new stream arrives (line 687):

```v
	// a stream more than we announced, or one more while what is held back waiting on
	// the client's windows is already as much as an HTTP/1.1 connection may hold
	if h.open >= h2_max_streams || h.held >= w.opts.max_pending || h.files >= h2_max_files {
		w.h2_reset(mut c, id, http2.err_refused_stream)
		return
	}
```

`h2_resume` is the single place both a due timer (`Loop.fire`,
`engine/worker_linux.c.v:193-197`) and an answered fetch (`Loop.answer`,
`engine/client_linux.c.v:48-49`) come back to (lines 979-1004):

```v
// h2_resume writes the response deferred on stream id, when its timer is due; false
// when the stream no longer waits for it (the client reset it, or the connection is
// closing).
fn (mut w Worker) h2_resume(mut c Conn, id u32) bool {
	mut h := c.h2
	i := h.find(id)
	if c.close_after || i < 0 || !h.streams[i].waiting {
		return false
	}
	s := &h.streams[i]
	cb := s.cb
	arg := s.arg
	method := s.method
	send_win := s.send_win
	h.release(i)
	mut x := &w.ctx
	...
	cb(mut x, arg)
	w.reply_done()
	w.h2_finish(mut c, id, 0, send_win)
	return true
}
```

Facts you can rely on (verified in the code):

- Every deferral creates exactly one thing that will call `h2_resume(c, id)` once:
  a timer (`w.timers.push(..., c.fd, c.gen, id)` in `h2_defer`, line 977) or a fetch
  waiter. A fetch always ends: reply, error, or timeout from the once-a-second sweep.
- HTTP/2 stream ids are never reused on a connection, and `h.find(id)` returns `-1`
  for a stream whose slot was released.
- If the connection itself closed, neither `fire` nor `answer` reaches `h2_resume`
  (they compare the connection's `gen` first), and `h2_open` resets the counters
  before the `H2Conn` object serves another connection.

Existing test to model on, `engine/h2_test.v:950-966` (helpers `open`, `feed`, `take`,
`fire`, `rst`, `Client.get`, `Client.responses`, `parse` are in that file; the route
`/defer` answers `late` after a 10 ms `c.after`):

```v
fn test_deferred_stream_reset() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := cl.get(1, '/defer')
	b << frame(http2.frame_rst_stream, 0, 1, [u8(0), 0, 0, 8]) // CANCEL
	feed(mut w, mut c, b)
	assert c.h2.open == 0 && c.h2.waiting == 0 && !c.h2_waits()
	assert fire(mut w, mut c) == 0
	assert take(mut w, mut c).len == 0
	...
```

The test helper `fire` (line 892) pops every timer and calls `w.h2_resume`.

### Part B — `engine/client.v`

`fetch_start` (lines 108-121) and `compact` (lines 171-179):

```v
	if p.queued() >= p.spec.opts.max_queue {
		w.fails << Fail{wt, .busy}
		return
	}
	off := p.q.len
	x.write_fetch(mut p.q, p.spec.host)
	p.items << Queued{
```

```v
fn (mut p Pool) compact() {
	if p.qhead == p.items.len {
		unsafe {
			p.q.len = 0
			p.items.len = 0
		}
		p.qhead = 0
		return
	}
```

`x` is the worker's `http1.Ctx`; `x.fetch_body` is the request body (a `[]u8` view)
that `write_fetch` will copy into `p.q`. `w.fails << Fail{wt, .busy}` answers the
fetch with the `.busy` error on this loop turn.

### Conventions

- **Zero allocation on the request path**, enforced by tests such as
  `test_h2_deferred_allocates_nothing` (`engine/h2_test.v:1029`) and
  `test_fetch_allocates_nothing`. `bash scripts/hotpath_lint.sh` greps `engine/h2.v`
  and `engine/client.v` for `${`, `.str()`, `.clone()`, `.trim`, `.split(`, slices.
  A line that allocates off the hot path ends with `// cold: <reason>`.
- Counters on `H2Conn` are plain `int` fields with a one-line trailing comment.
- **Edit `.v` files with a file-editing tool, never shell heredocs/`sed`/Python.**

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Link the module (once) | `bash scripts/install.sh` | prints `linked: ...` |
| Format | `v fmt -w <changed files>` then `v fmt -verify .` | exit 0 |
| HTTP/2 engine tests (any OS) | `v test engine/h2_test.v` | all pass |
| HTTP/2 fuzz | `VILTRUM_FUZZ_ITERS=200000 v test engine/h2_test.v` | all pass |
| Client socket tests (**Linux only**) | `v test engine/client_linux_test.v` | all pass |
| Whole suite | `v test http1/ http2/ jsonenc/ router/ engine/ tests/` | all pass |
| Hot-path lint | `bash scripts/hotpath_lint.sh` | `hot path clean` |

If you are not on Linux, run the portable commands and set the status to
`BLOCKED (Linux-only tests not run)` instead of DONE.

## Scope

**In scope**:

- `engine/h2.v`
- `engine/h2_test.v`
- `engine/client.v`
- `docs/http2.md`, `docs/client.md` (one sentence each)

**Out of scope**:

- `engine/client_linux.c.v`, `engine/worker_linux.c.v`, `engine/timers.v` — no change
  is needed there; if you think one is, stop.
- Cancelling the upstream request when the stream is reset. The design
  (`docs/design/1.x-client.md`) decided: "A reply whose waiter is gone ... is read to
  its end and dropped, and the peer is reused." Keep that.
- The `h.flood` counter and `h2_flood`. Do not change when it resets.
- A new public option for the byte limit. The project keeps its option surface small;
  use a constant.

## Git workflow

- Branch from the branch that has plan 001 applied: `advisor/003-h2-reset-queue-bounds`.
- Conventional Commits, e.g.
  `fix(h2): count a reset stream's deferred work against the stream limit`,
  `fix(client): bound the fetch queue in bytes and give its buffer back`.
- Do NOT push or open a PR unless told to. Do not change git config.

## Steps

### Step 1: Failing test for Part A

In `engine/h2_test.v`, after `test_deferred_stream_reset`, add:

```v
// Resetting a stream that waits does not hand its slot to the next request: the
// timer (or fetch) it started is still out, and counts until it is due.
fn test_reset_streams_keep_counting_until_due() {
	mut w := new_worker(h2_router(), Options{ send_date: false }, 0)
	mut c := open(mut w, [])
	mut cl := Client{}
	mut b := []u8{}
	for k in 0 .. 300 {
		id := u32(2 * k + 1)
		b << cl.get(id, '/defer')
		b << rst(id)
	}
	feed(mut w, mut c, b)
	assert !c.close_after
	assert c.h2.open == 0 && c.h2.waiting == 0
	assert c.h2.orphans == h2_max_streams
	assert w.timers.a.len == h2_max_streams
	// the streams past the limit were refused
	fs := parse(take(mut w, mut c))
	refused := fs.filter(it.typ == http2.frame_rst_stream)
	assert refused.len == 300 - h2_max_streams
	// once the timers are due the connection takes requests again
	assert fire(mut w, mut c) == 0
	assert c.h2.orphans == 0
	feed(mut w, mut c, cl.get(601, '/baseline2?a=1&b=2'))
	r := cl.responses(parse(take(mut w, mut c)))
	assert r[601].body == '3'.bytes()
}
```

(`/baseline2?a=1&b=2` answers `3`; it is used the same way in `test_deferred_and_404`.
`Frame` has fields `typ`, `flags`, `payload`. If a helper's shape differs slightly,
adapt the test minimally and keep every assertion.)

**Verify**: `v test engine/h2_test.v` → fails to compile (`orphans` unknown). That is
the expected "red" state.

### Step 2: Count orphans

In `engine/h2.v`:

a) `H2Conn`: after the `waiting` field add

```v
	orphans    int // streams reset while waiting: their timer or fetch is still out
```

b) `h2_open`: after `h.waiting = 0` add `h.orphans = 0`.

c) `release`: change the `if s.waiting {` block to

```v
	if s.waiting {
		// its timer or fetch finds the stream gone and is dropped (h2_resume); until
		// then it still counts against the streams this connection may have open
		h.waiting--
		h.orphans++
		s.waiting = false
	}
```

d) `h2_resume`: the normal path must not count as an orphan, and a resume that finds
no stream settles one. Replace the start of the function body with:

```v
	mut h := c.h2
	i := h.find(id)
	if i < 0 && h.orphans > 0 {
		h.orphans-- // the timer or fetch of a stream reset meanwhile
	}
	if c.close_after || i < 0 || !h.streams[i].waiting {
		return false
	}
	s := &h.streams[i]
	cb := s.cb
	arg := s.arg
	method := s.method
	send_win := s.send_win
	h.streams[i].waiting = false // answered here, not orphaned
	h.waiting--
	h.release(i)
```

(The rest of the function is unchanged.)

e) The limit check (line 687): change `h.open >= h2_max_streams` to
`h.open + h.orphans >= h2_max_streams`, and extend its comment with
`(streams reset while their deferred response was out count until it is due)`.

**Verify**: `v test engine/h2_test.v` → all pass, including
`test_reset_streams_keep_counting_until_due`, `test_deferred_stream_reset`,
`test_deferred_and_404`, `test_stream_limit`, `test_h2_deferred_allocates_nothing`.

### Step 3: Fuzz the HTTP/2 path once

**Verify**: `VILTRUM_FUZZ_ITERS=200000 v test engine/h2_test.v` → all pass (no panic,
no failed assertion).

### Step 4: Part B — byte bound and shrink for the fetch queue

In `engine/client.v`:

a) Add constants below the `import` lines' doc comment block (near the top, before
`struct Waiter`):

```v
// What a pool's queue may hold in bytes besides max_queue's count (a queued fetch
// carries its whole request, body included), and the buffer size kept once it is empty.
const queue_max_bytes = 16 * 1024 * 1024
const queue_keep_bytes = 64 * 1024
```

b) In `fetch_start`, replace the `if p.queued() >= p.spec.opts.max_queue {` condition
with:

```v
	// one request always fits, whatever its size; past that the queue's bytes are bounded
	if p.queued() >= p.spec.opts.max_queue
		|| (p.q.len > 0 && p.q.len + x.fetch_body.len > queue_max_bytes) {
```

c) In `Pool.compact`, in the `if p.qhead == p.items.len {` branch, before `return`:

```v
		if p.q.cap > queue_keep_bytes {
			p.q = []u8{} // cold: a burst of large requests, given back
		}
```

**Verify**: `v test engine/h2_test.v` passes; on Linux
`v test engine/client_linux_test.v` → all pass (including
`test_fetch_queues_past_max_conns` and `test_fetch_allocates_nothing`).

### Step 5: Documentation

- `docs/http2.md`: find the section that lists limits (`grep -n -i "limit\|128" docs/http2.md`)
  and add one sentence: "A stream reset while its response is deferred (`c.after`,
  `c.fetch`) keeps counting toward the 128 concurrent streams until its timer is due or
  its fetch is answered, so resetting streams does not buy more deferred work."
- `docs/client.md`, Options table, the `max_queue` row: change the description to
  "Fetches that wait for a connection; past it, or past 16 MiB of queued requests,
  `.busy` at once."

**Verify**: `grep -n "16 MiB" docs/client.md` → one match.

### Step 6: Format, lint, full suite

**Verify**:
- `v fmt -w engine/h2.v engine/h2_test.v engine/client.v && v fmt -verify .` → exit 0
- `bash scripts/hotpath_lint.sh` → `hot path clean`
- `v test http1/ http2/ jsonenc/ router/ engine/ tests/` → all pass
- `v -d viltrum_debug test router/ engine/ tests/` → all pass

## Test plan

- New: `test_reset_streams_keep_counting_until_due` in `engine/h2_test.v` (300
  HEADERS+RST pairs: exactly 128 timers, the rest refused, counter back to 0 after the
  timers fire, connection usable again). Model: `test_deferred_stream_reset`.
- Part B has no new test in this plan: the byte bound needs requests of megabytes on a
  saturated pool. Plan 004 adds the `.busy` test for the count bound; the byte bound is
  covered by code review. Say so in your report.
- Must still pass: `test_h2_allocates_nothing`, `test_h2_deferred_allocates_nothing`,
  `test_h2_fuzz`, `test_fetch_allocates_nothing`.

## Done criteria

- [ ] `grep -n "orphans" engine/h2.v` → at least 6 matches (field, reset, release, two in `h2_resume`, limit check)
- [ ] `grep -n "h.open + h.orphans >= h2_max_streams" engine/h2.v` → one match
- [ ] `grep -n "queue_max_bytes" engine/client.v` → two matches
- [ ] `v test engine/h2_test.v` exits 0 with the new test
- [ ] `VILTRUM_FUZZ_ITERS=200000 v test engine/h2_test.v` exits 0
- [ ] `v test http1/ http2/ jsonenc/ router/ engine/ tests/` exits 0
- [ ] `bash scripts/hotpath_lint.sh` prints `hot path clean`; `v fmt -verify .` exits 0
- [ ] `git status --short` lists only in-scope files (plus `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The code at the locations in "Current state" does not match the excerpts.
- After Step 2, `c.h2.orphans` is not 0 at the end of a pre-existing test that ends
  with all timers fired (add a temporary assert to check if a test fails oddly), or
  `test_stream_limit` / `test_deferred_and_404` fail. That means some path calls
  `release` on a waiting stream and nothing later calls `h2_resume` for it — an
  orphan that never settles would shrink the connection's stream limit for good. Do
  not paper over it (no "reset to 0 somewhere"): report the path.
- You find a call site of `h2_resume` other than `Loop.fire`
  (`engine/worker_linux.c.v`), `Loop.answer` (`engine/client_linux.c.v`) and the tests.
- The fuzz run in Step 3 fails.
- Any zero-allocation test fails.

## Maintenance notes

- Invariant to keep: **every `release` of a waiting stream is followed by exactly one
  `h2_resume` for that stream id, or by the connection closing.** New ways to defer a
  response over HTTP/2 must keep it, or `orphans` drifts.
- A connection whose client resets 128 deferred streams is refused new streams
  (`REFUSED_STREAM`) for as long as the longest deferral lasts — for a fetch, at most
  the upstream `timeout` (10 s default) plus the 1 s sweep. That is the intended cost.
- This bounds deferred work per connection. Bounding it per client across many
  connections is `max_conns` and a reverse proxy's job, as for HTTP/1.1.
- `queue_max_bytes` is a constant on purpose. If an app forwards bodies larger than
  16 MiB on a saturated pool it will see `.busy` earlier than `max_queue` says; turn
  the constant into an `UpstreamOptions` field only when someone needs that.
- Reviewer: read `h2_resume` and `release` together and check the three counters
  (`open`, `waiting`, `orphans`) for the four cases: normal resume, reset then timer,
  reset then fetch reply, connection close.
