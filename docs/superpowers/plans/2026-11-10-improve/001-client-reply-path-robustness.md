# Plan 001: The fetch client survives early, oversized, repeated-1xx and ambiguously framed upstream replies

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat acb27f3..HEAD -- engine/client_linux.c.v engine/client.v http1/reply.v http1/reply_test.v engine/client_linux_test.v`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug / security
- **Planned at**: commit `acb27f3`, 2026-11-10 (branch `feat/http-client`)

## Why this matters

Viltrum's new HTTP client (`c.fetch`) keeps connections to an upstream service in a
per-worker pool and shares them between the requests of different end users. Four
defects in how a reply is read let one upstream reply damage other users' fetches or
stall a worker (a worker is a single-threaded event loop serving thousands of
connections):

1. **Early reply, connection reused out of sync.** If the upstream answers before the
   whole request was sent (e.g. `401` to a large `POST`), the connection goes back to
   the pool with the request half-sent. The next fetch is written into the middle of
   the previous request's body.
2. **Unlimited `1xx` replies.** Each interim reply moves the whole read buffer; an
   upstream that sends thousands of them freezes the worker.
3. **Full buffer, no failure.** When the read buffer reaches its cap and the reply is
   still not whole, the client stops reading but does not fail the fetch. The socket
   stays readable, so the event loop spins at 100% CPU until the fetch timeout (10 s).
4. **Repeated `Content-Length` / `Transfer-Encoding`.** The reply parser uses the first
   and ignores the rest; the request parser already refuses these.

After this plan each of the four ends the fetch at once with the right `FetchError`
and closes the connection.

## Current state

Files:

- `engine/client_linux.c.v` — the client's socket code (Linux only). `peer_read`
  (line 150) reads and frames a reply; `peer_release` (line 251) pools the connection.
- `engine/client.v` — `Peer` struct (line 27) and `Peer.begin` (line 138).
- `http1/reply.v` — `frame_reply` (line 55), portable reply framing.
- `http1/reply_test.v` — unit tests for `frame_reply` (portable).
- `engine/client_linux_test.v` — socket tests (Linux only) with a scripted upstream
  `raw_upstream` (line 351).

`engine/client_linux.c.v:150-220` today:

```v
fn (mut l Loop) peer_read(mut peer Peer) {
	max := l.w.pools[peer.pool].spec.opts.max_reply
	mut eof := false
	for {
		if peer.rbuf.len == peer.rbuf.cap {
			if peer.rbuf.cap > max + 64 * 1024 {
				break // frame_reply refuses it
			}
			unsafe { peer.rbuf.grow_cap(peer.rbuf.cap) } // cold: a reply larger than the buffer
		}
		...
	}
	if eof && peer.rbuf.len == 0 {
		l.peer_lost(mut peer)
		return
	}
	for {
		n := http1.frame_reply(peer.rbuf, mut peer.frame, peer.head, eof, max) or {
			l.peer_fail(mut peer, match err.code() {
				413 { http1.FetchError.too_big }
				503 { http1.FetchError.closed }
				else { http1.FetchError.protocol }
			})
			return
		}
		if n < 0 {
			return
		}
		if peer.frame.interim {
			// a 1xx head: drop it, the reply follows
			rest := peer.rbuf.len - n
			unsafe {
				C.memmove(peer.rbuf.data, &u8(peer.rbuf.data) + n, rest)
				peer.rbuf.len = rest
			}
			peer.frame.reset()
			continue
		}
		body := http1.reply_body(peer.rbuf, &peer.frame, n)
		keep := peer.frame.keep && !eof && n == peer.rbuf.len
		...
		l.answer(wt)
		l.peer_release(mut peer, keep)
		return
	}
}
```

The comment `// frame_reply refuses it` is wrong: `frame_reply` returns `-1` ("need
more bytes") for a chunked reply whose chunk lines are long but whose data is small,
because `http1/chunked.v:82` counts only data bytes against the limit.

`engine/client.v:27-43` (`Peer`) and `:138-149` (`begin`):

```v
struct Peer {
mut:
	fd          int = -1
	pool        int
	rbuf        []u8
	wbuf        []u8 // the request, kept whole until its reply so it can be sent again
	woff        int
	...
	deadline_ms i64 // the reply's, while busy; the idle timeout's, while idle
}

fn (mut peer Peer) begin(wt Waiter, head bool, idem bool) {
	peer.waiter = wt
	peer.head = head
	peer.idem = idem
	peer.retried = false
	peer.busy = true
	peer.woff = 0
	peer.frame.reset()
	unsafe {
		peer.rbuf.len = 0
	}
}
```

`peer.woff` is how many bytes of `peer.wbuf` were sent. The request is fully sent
exactly when `peer.woff == peer.wbuf.len`.

`http1/reply.v:55-111` (inside `frame_reply`):

```v
		f.head_end = end
		h := view(buf, 0, end)
		if !clean_head(h) {
			return refuse(502, 'bad reply head')
		}
		minor := status_line(h, mut f)!
		if f.status < 200 {
			...
			f.interim = true
			return end
		}
		mut te := Span{}
		mut cl := Span{}
		mut ex := Span{}
		framing_fields(h, mut te, mut cl, mut ex)
		...
		} else if cl.found() {
			n := parse_content_length(view(h, cl.start, cl.len)) or {
				return refuse(502, 'bad content-length')
			}
			if n > max {
				return refuse(413, 'reply too large')
			}
			f.content_length = int(n)
```

`framing_fields` (`http1/frame.v:196`) keeps only the first field of each name. It is
shared with the request hot path: **do not change it**.

Conventions that apply:

- **Zero allocation per request.** Code on the request path must not allocate.
  `bash scripts/hotpath_lint.sh` greps `engine/client_linux.c.v`, `engine/client.v`
  and `http1/reply.v` for `${`, `.str()`, `.clone()`, `.bytestr()`, `.trim`,
  `.split(`, slicing `a[x..y]`. A line that really is off the hot path may end with
  `// cold: <reason>`. Do not use those constructs in the non-test code you add.
- Errors from framing use `refuse(code, 'reason')` (see the excerpt). 413 maps to
  `.too_big`, 503 to `.closed`, anything else to `.protocol`.
- Comments say *why*, in one or two lines, in the style of the excerpts above.
- **Edit `.v` files with a file-editing tool, never with shell heredocs, `sed`, or
  inline Python.** Shell tools turn the `\r` `\n` `\t` escapes inside V string
  literals into real control characters and corrupt the file.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Link the module (once) | `bash scripts/install.sh` | prints `linked: ...` |
| Format | `v fmt -w <files you changed>` then `v fmt -verify .` | exit 0 |
| Reply unit tests (any OS) | `v test http1/reply_test.v` | all pass |
| Client socket tests (**Linux only**) | `v test engine/client_linux_test.v` | all pass |
| Whole suite | `v test http1/ http2/ jsonenc/ router/ engine/ tests/` | all pass |
| Hot-path lint | `bash scripts/hotpath_lint.sh` | prints `hot path clean` |

V 0.5.2 is the supported compiler. Files named `*_linux_test.v` only compile and run
on Linux. If you are not on Linux, do the code changes, run every portable command,
and set this plan's status to `BLOCKED (Linux-only tests not run)` — do not mark it
DONE.

## Scope

**In scope** (the only files you should modify):

- `engine/client_linux.c.v`
- `engine/client.v` (one field on `Peer`, one line in `begin`)
- `http1/reply.v`
- `http1/reply_test.v`
- `engine/client_linux_test.v`

**Out of scope** (do NOT touch):

- `http1/frame.v`, `http1/chunked.v`, `http1/parse.v` — shared with the request hot
  path, which is gated on instruction counts in CI.
- `http1/ctx.v` — plan 002 changes it.
- `engine/h2.v` — plan 003 changes it.
- `docs/` — no documented behaviour changes here (`docs/client.md` already says
  `max_reply` is "Head and body together").

## Git workflow

- Start from branch `feat/http-client` (the client only exists there). Branch:
  `advisor/001-client-reply-path`.
- One commit per step or one for the plan. Conventional Commits, e.g.
  `fix(client): close a pooled connection whose request was not fully sent`.
- Do NOT push or open a PR unless the operator told you to. Do not change git config.

## Steps

### Step 1: Write the failing socket tests (Linux)

In `engine/client_linux_test.v`, after `test_fetch_reply_shapes`, add:

a) A helper upstream that answers a `POST` before reading its body, and otherwise
answers with the number of the connection (`1` for the first accepted):

```v
// early_upstream answers a POST as soon as its head is in, then reads nothing for
// a while: a reply that overtakes its request. Any other request gets 200 with the
// number of the connection it came on.
fn early_upstream() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := (l.addr() or { panic(err) }).str()
	spawn fn [l] () {
		mut ln := l
		mut k := 0
		for {
			conn := ln.accept() or { return }
			k++
			spawn fn [conn, k] () {
				mut c := conn
				mut acc := []u8{}
				mut tmp := []u8{len: 4096}
				for {
					end := head_end(acc)
					if end < 0 {
						n := c.read(mut tmp) or { 0 }
						if n <= 0 {
							c.close() or {}
							return
						}
						acc << tmp[..n]
						continue
					}
					if acc[..4].bytestr() == 'POST' {
						c.write_string('HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n') or {}
						time.sleep(500 * time.millisecond)
						for {
							n := c.read(mut tmp) or { 0 }
							if n <= 0 {
								break
							}
						}
						c.close() or {}
						return
					}
					acc = acc[end..].clone()
					c.write_string('HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n${k}') or {}
				}
			}()
		}
	}()
	return addr
}
```

b) A front-server starter that takes engine options (the existing `start_front` does
not):

```v
fn start_front_opts(up_addr string, uo UpstreamOptions, o Options) (string, &Stop) {
	spec := new_upstream('http://${up_addr}', uo) or { panic(err) }
	return serve_on(front_router(), Options{
		...o
		upstreams: [spec]
	}, false)
}
```

c) Three tests:

```v
// A reply that arrives while the request is still going out must not leave the
// connection in the pool: the next fetch would land in the middle of that request.
fn test_early_reply_closes_the_connection() {
	front, mut stop := start_front_opts(early_upstream(), UpstreamOptions{ max_conns: 1 },
		Options{
		limits: http1.Limits{
			max_body_bytes: 64 * 1024 * 1024
		}
	})
	defer {
		stop.request()
	}
	mut c := dial(front)
	mut r := Reader{}
	body := 'x'.repeat(32 * 1024 * 1024)
	c.write_string('POST /f-post HTTP/1.1\r\nHost: x\r\nContent-Length: ${body.len}\r\n\r\n') or {
		panic(err)
	}
	c.write_string(body) or { panic(err) }
	st, _ := r.response(mut c) or { panic(err) }
	assert st == 401
	// the same client connection stays on its worker, so on the same pool
	st2, b2 := get(mut c, mut r, '/f/x')
	assert st2 == 200 && b2 == '2', b2
	c.close() or {}
}

fn script_many_interims(n int) (string, bool) {
	return 'HTTP/1.1 100 Continue\r\n\r\n'.repeat(20) +
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok', true
}

// 40 one-byte chunks whose size lines carry 4000 bytes of extension each: 40 bytes of
// data, 160 KiB on the wire.
fn script_padded_chunks(n int) (string, bool) {
	chunk := '1;' + 'a'.repeat(4000) + '\r\nx\r\n'
	return 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' + chunk.repeat(40) +
		'0\r\n\r\n', false
}

fn test_fetch_hostile_replies_end_at_once() {
	front, mut stop := start_front(raw_upstream(script_many_interims), UpstreamOptions{},
		false)
	mut c := dial(front)
	mut r := Reader{}
	st, body := get(mut c, mut r, '/f/x')
	assert st == 599 && body == 'protocol', body
	c.close() or {}
	stop.request()

	front2, mut stop2 := start_front(raw_upstream(script_padded_chunks), UpstreamOptions{
		max_reply: 1000
		timeout:   6 * time.second
	}, false)
	mut c2 := dial(front2)
	mut r2 := Reader{}
	t0 := time.sys_mono_now()
	st2, body2 := get(mut c2, mut r2, '/f/x')
	assert st2 == 599 && body2 == 'too_big', body2
	assert time.sys_mono_now() - t0 < 3 * u64(time.second)
	c2.close() or {}
	stop2.request()
}
```

The helpers `dial`, `Reader`, `get`, `head_end`, `raw_upstream`, `start_front`,
`serve_on`, `front_router` already exist in this file; `/f-post` forwards the request
body with `c.fetch_body(c.body())` and `/f/*rest` fetches `GET /<rest>`; the callback
answers `599` with the error's name on failure.

If the snippets do not compile as written, make the smallest change that keeps their
meaning (they were written against the code without compiling).

**Verify** (Linux): `v test engine/client_linux_test.v` → the two new tests FAIL
(the first after about 10 s with body `timeout` instead of `2`; the second with
`body == 'ok'` for the interims and `timeout` for the chunks). Every pre-existing test
still passes. If `test_early_reply_closes_the_connection` passes before any fix, see
STOP conditions.

### Step 2: Do not pool a connection whose request was not fully sent

In `engine/client_linux.c.v`, `peer_read`, change the `keep` line to:

```v
		// a reply that overtook its request leaves unsent bytes the upstream still expects
		keep := peer.frame.keep && !eof && n == peer.rbuf.len && peer.woff == peer.wbuf.len
```

**Verify** (Linux): `v test engine/client_linux_test.v` →
`test_early_reply_closes_the_connection` passes.

### Step 3: Cap interim replies

- `engine/client.v`: add `interims int // 1xx heads dropped for this request` to
  `Peer` (after `retried`), and `peer.interims = 0` in `Peer.begin`.
- `engine/client_linux.c.v`: add near the other constants at the top
  `const peer_max_interims = 8 // 1xx replies one request may get`.
- In `peer_read`'s `if peer.frame.interim {` branch, before the `memmove`:

```v
			peer.interims++
			if peer.interims > peer_max_interims {
				l.peer_fail(mut peer, .protocol)
				return
			}
```

**Verify** (Linux): the interim half of `test_fetch_hostile_replies_end_at_once`
passes; `test_fetch_reply_shapes` (one `100 Continue`) still passes.

### Step 4: Fail the fetch when the buffer is at its cap and the reply is not whole

In `peer_read`, replace

```v
		if n < 0 {
			return
		}
```

with

```v
		if n < 0 {
			// the read loop stopped at the cap: nothing more will be read, and the
			// socket would stay readable and wake the loop on every turn
			if peer.rbuf.len == peer.rbuf.cap && peer.rbuf.cap > max + 64 * 1024 {
				l.peer_fail(mut peer, .too_big)
			}
			return
		}
```

and change the stale comment in the read loop from `// frame_reply refuses it` to
`// the framing below ends the fetch`.

**Verify** (Linux): `v test engine/client_linux_test.v` → all pass, including both
halves of `test_fetch_hostile_replies_end_at_once`.

### Step 5: `max_reply` covers head plus body; repeated framing fields are refused

In `http1/reply.v`, `frame_reply`:

a) Right after `end := find_head_end(buf, f.scanned)` is known to be `>= 0` (just
before `f.head_end = end`), add:

```v
		if end > max {
			return refuse(413, 'reply too large')
		}
```

b) Change `if n > max {` (the Content-Length check) to `if n > max - end {` — the
limit is head and body together, and `end <= max` holds from (a).

c) Right after the `framing_fields(h, mut te, mut cl, mut ex)` line, add:

```v
		if repeated_framing(h) {
			return refuse(502, 'repeated framing field')
		}
```

d) Add these two functions to `http1/reply.v` (after `clean_head`):

```v
// repeated_framing is whether a reply head has more than one Content-Length or more
// than one Transfer-Encoding field: framing_fields reads only the first of each, and
// a reply framed two ways must not be guessed at.
@[direct_array_access]
fn repeated_framing(head []u8) bool {
	mut ncl := 0
	mut nte := 0
	mut i := crlf_at(head, 0) + 2
	for i + 1 < head.len {
		j := crlf_at(head, i)
		if j == i {
			break
		}
		c := head[i] | 0x20
		if c == `c` && field_named(head, i, j, 'content-length') {
			ncl++
		} else if c == `t` && field_named(head, i, j, 'transfer-encoding') {
			nte++
		}
		i = j + 2
	}
	return ncl > 1 || nte > 1
}

// field_named is whether the line head[i..j] is a field named name_lower.
@[direct_array_access]
fn field_named(head []u8, i int, j int, name_lower string) bool {
	if j - i <= name_lower.len || head[i + name_lower.len] != `:` {
		return false
	}
	for k in 0 .. name_lower.len {
		if lower(head[i + k]) != name_lower[k] {
			return false
		}
	}
	return true
}
```

(`crlf_at` and `lower` already exist in package `http1`; the loop is the same walk
`framing_fields` and `reply_header` use.)

e) In `http1/reply_test.v`, find the test with a `cases := {` map of
`reply string: error code` (it ends with the `for s, code in cases {` loop near line
108). Add three entries:

```v
		'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab':                         502
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n': 502
		'HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n':                                          413
```

(The helper `reply_of` in that file frames with `max = 1024 * 1024`, so a body of
exactly 1 MiB plus a head is past the limit.)

**Verify**: `v test http1/reply_test.v` → all pass. `v test http1/fuzz_test.v` → pass.

### Step 6: Format, lint, full suite

**Verify**:
- `v fmt -w engine/client_linux.c.v engine/client.v http1/reply.v http1/reply_test.v engine/client_linux_test.v && v fmt -verify .` → exit 0
- `bash scripts/hotpath_lint.sh` → `hot path clean`
- `v test http1/ http2/ jsonenc/ router/ engine/ tests/` → all pass

## Test plan

- New socket tests (Linux): `test_early_reply_closes_the_connection`,
  `test_fetch_hostile_replies_end_at_once` in `engine/client_linux_test.v`, modelled on
  `test_fetch_reply_shapes` in the same file.
- New unit cases: three entries in the error-code table of `http1/reply_test.v`.
- The existing `test_fetch_allocates_nothing` (same file) is the zero-allocation gate
  for the client and must still pass.

## Done criteria

- [ ] `grep -n "peer.woff == peer.wbuf.len" engine/client_linux.c.v` → one match on the `keep` line
- [ ] `grep -n "peer_max_interims" engine/client_linux.c.v` → at least two matches
- [ ] `grep -n "fn repeated_framing" http1/reply.v` → one match
- [ ] `v test http1/reply_test.v` exits 0
- [ ] On Linux: `v test engine/client_linux_test.v` exits 0, including the 2 new tests
- [ ] `v test http1/ http2/ jsonenc/ router/ engine/ tests/` exits 0
- [ ] `bash scripts/hotpath_lint.sh` prints `hot path clean`; `v fmt -verify .` exits 0
- [ ] `git status --short` lists only the five in-scope files (plus `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the locations in "Current state" does not match the excerpts.
- `test_early_reply_closes_the_connection` passes **before** Step 2. Then the request
  was sent whole before the reply came (socket buffers took 32 MiB). Try a 128 MiB body
  with `max_body_bytes: 256 * 1024 * 1024` once; if it still passes, keep the fix,
  report that the test does not reproduce the bug, and do not claim the test covers it.
- `test_fetch_allocates_nothing` fails after your change (an allocation crept in).
- Any pre-existing test in `engine/client_linux_test.v` or `http1/reply_test.v` fails
  after a step and one fix attempt does not resolve it.
- You find you need to change `http1/frame.v`, `http1/chunked.v` or `http1/parse.v`.

## Maintenance notes

- `peer_max_interims = 8` is a judgment call (real servers send one or two). It is a
  constant, not an option, on purpose: the project keeps its public surface small.
- The cap check in Step 4 relies on the read loop's own cap rule
  (`cap > max + 64 KiB`). If that rule changes, change both together.
- Streaming reply bodies (not planned in Phase 9) would replace the whole-reply
  buffering and with it Steps 4 and 5(a,b).
- Reviewer: check that `keep` is still false whenever `eof` is true, and that the new
  socket tests take seconds, not the 10 s fetch timeout.
- Deferred: a connection reused after a `HEAD`/`204`/`304` reply whose upstream sends a
  stray body later is closed only if the bytes arrive while it is idle
  (`on_peer`, `!peer.busy`). Not changed here.
