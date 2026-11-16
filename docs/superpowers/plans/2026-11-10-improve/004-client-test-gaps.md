# Plan 004: The fetch client's backpressure, queue expiry, idle close and URL validation are tested

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat acb27f3..HEAD -- engine/client_linux_test.v engine/upstream.v engine/client.v engine/client_linux.c.v`
> Plans 001 and 003 change these files (new tests and helpers in
> `client_linux_test.v`, small changes in `client.v` / `client_linux.c.v`). That is
> expected. What must still hold: the helpers named in "Current state" exist with the
> same signatures, and `new_upstream` still validates as excerpted. Otherwise STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (tests only)
- **Depends on**: plans/001-client-reply-path-robustness.md (same test file; apply after it to avoid conflicts). Independent of 002 and 003.
- **Category**: tests
- **Planned at**: commit `acb27f3`, 2026-11-10 (branch `feat/http-client`)

## Why this matters

The HTTP client (`c.fetch`) is new and its tests cover the happy path, timeouts on an
in-flight request, oversized replies, refused connections, and garbage replies. Not
covered at all: the `.busy` answer when the pool and queue are full, the timeout of a
fetch that never left the queue, closing idle pooled connections, a client that goes
away while its fetch is out, and every validation branch of the upstream URL parser.
These are the paths that keep a slow upstream from piling work up, and nothing would
notice if a change broke them. This plan adds characterization tests: **no production
code changes**.

## Current state

Production code under test (do not modify):

`engine/client.v:100-111` — a fetch takes a connection, or queues, or answers `.busy`:

```v
	if p.idle.len > 0 || p.open < p.spec.opts.max_conns {
		mut peer := w.take_peer(mut p, id)
		...
		return
	}
	if p.queued() >= p.spec.opts.max_queue {
		w.fails << Fail{wt, .busy}
		return
	}
```

`engine/client_linux.c.v`, `sweep_peers` (runs once a second) — closes idle
connections past `idle_timeout`, fails in-flight fetches past `timeout`, and answers
queued fetches past their deadline with `.timeout`:

```v
		if l.now > peer.deadline_ms {
			if peer.busy {
				l.peer_fail(mut peer, .timeout)
			} else {
				l.peer_close(mut peer)
			}
		}
	...
		for p.queued() > 0 && p.items[p.qhead].deadline_ms < l.now {
			l.w.fails << Fail{p.items[p.qhead].waiter, .timeout}
			p.qhead++
		}
```

`engine/upstream.v:9-17` and `:29-52`:

```v
pub struct UpstreamOptions {
pub:
	max_conns    int           = 64               // connections open to the upstream
	max_queue    int           = 1024             // fetches waiting for one; past it they answer .busy
	timeout      time.Duration = 10 * time.second // from the fetch to the whole reply
	idle_timeout time.Duration = 30 * time.second // a pooled connection unused this long closes
	max_reply    int           = 1024 * 1024      // head and body; past it the fetch answers .too_big
}
```

```v
pub fn new_upstream(url string, opts UpstreamOptions) !UpstreamSpec {
	if url.starts_with('https://') {
		return error('viltrum: TLS upstreams are not supported yet: ${url}')
	}
	if !url.starts_with('http://') {
		return error('viltrum: an upstream URL starts with http:// (${url})')
	}
	host := url[7..].trim_right('/')
	if host.len == 0 {
		return error('viltrum: an upstream URL names a host (${url})')
	}
	for b in host {
		if b <= 0x20 || b == 0x7f || b == `/` || b == `?` || b == `#` || b == `@` {
			return error('viltrum: an upstream URL is http://host[:port], no path (${url})')
		}
	}
	has_port := if host.starts_with('[') { host.contains(']:') } else { host.contains(':') }
	addrs := net.resolve_addrs(if has_port { host } else { host + ':80' }, .unspec, .tcp)!
	...
	if opts.max_conns < 1 || opts.max_queue < 0 || opts.max_reply < 1 {
		return error('viltrum: upstream ${host}: max_conns and max_reply must be positive')
	}
	return UpstreamSpec{
		host: host
		addr: addrs[0]
		opts: opts
	}
}
```

Test helpers that already exist in `engine/client_linux_test.v` (Linux only):

- `start(opts Options) (string, &Stop)` — a viltrum server used as the upstream. Its
  routes: `GET /p/*rest` answers the path, `GET /delay/:ms` answers after `ms`
  milliseconds with the number, `POST /echo`, `GET /big`.
- `start_front(up_addr string, uo UpstreamOptions, h2 bool) (string, &Stop)` — the
  server under test, **2 workers**, whose handlers fetch from the upstream:
  `GET /f/*rest` fetches `GET /<rest>` and answers the upstream's status and body, or
  status `599` with the error's name (`busy`, `timeout`, ...) as the body.
- `raw_upstream(script fn (n int) (string, bool)) string` — a scripted upstream:
  `script(n)` gives the reply to the n-th request **on each connection** and whether
  to close after it.
- `dial(addr) &net.TcpConn`, `Reader{}`, `get(mut c, mut r, path) (int, string)`.
- Stopping: `defer { stop.request() }` after each `start`/`start_front`.

Each worker has its own pool, and a client connection stays on one worker. With 2
workers and `max_conns: 1`, at most 2 fetches are in flight at once across the server.

Example of the existing style (`engine/client_linux_test.v:284-310`):

```v
fn test_fetch_queues_past_max_conns() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{ max_conns: 1 }, false)
	defer {
		stop.request()
	}
	ch := chan string{cap: 16}
	for i in 0 .. 16 {
		spawn fn [front, i, ch] () {
			mut c := dial(front)
			mut r := Reader{}
			_, body := get(mut c, mut r, '/f/delay/${20 + i}')
			ch <- body
			c.close() or {}
		}()
	}
	...
```

Conventions: tests are plain `fn test_...()` functions with `assert`; a short comment
above each says what behaviour it pins down. **Edit `.v` files with a file-editing
tool, never shell heredocs/`sed`/Python** (escapes like `\r\n` get corrupted).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Link the module (once) | `bash scripts/install.sh` | prints `linked: ...` |
| Format | `v fmt -w <changed files>` then `v fmt -verify .` | exit 0 |
| URL tests (any OS) | `v test engine/upstream_test.v` | all pass |
| Client socket tests (**Linux only**) | `v test engine/client_linux_test.v` | all pass |
| Whole suite | `v test http1/ http2/ jsonenc/ router/ engine/ tests/` | all pass |

If you are not on Linux: do Step 1 fully and write Step 2's tests, but they can
neither be compiled nor run there, so set the status to
`BLOCKED (Linux-only tests not run)` instead of DONE.

## Scope

**In scope**:

- `engine/upstream_test.v` (create)
- `engine/client_linux_test.v` (add tests and one script function at the end)

**Out of scope**:

- Every non-test file. If a new test fails because the production code behaves
  differently from what this plan describes, that is a finding to report, not
  something to fix here.
- Refactoring the existing test helpers (they are duplicated across three test
  files; that clean-up is deliberately not part of this plan).

## Git workflow

- Branch from the branch that has plan 001 applied: `advisor/004-client-test-gaps`.
- Conventional Commits: `test(client): busy, queued timeout, idle close, client gone, upstream URLs`.
- Do NOT push or open a PR unless told to. Do not change git config.

## Steps

### Step 1: Upstream URL validation (portable)

Create `engine/upstream_test.v`:

```v
module engine

// Literal addresses only: nothing here asks DNS.

fn test_new_upstream_accepts() {
	a := new_upstream('http://127.0.0.1:9', UpstreamOptions{})!
	assert a.host == '127.0.0.1:9'
	// no port: 80 is dialled, and Host stays as the URL gave it
	b := new_upstream('http://127.0.0.1/', UpstreamOptions{})!
	assert b.host == '127.0.0.1'
	c := new_upstream('http://127.0.0.1:9', UpstreamOptions{ max_queue: 0 })!
	assert c.opts.max_queue == 0
}

fn test_new_upstream_refuses() {
	for url in ['https://127.0.0.1', '127.0.0.1:80', 'ftp://127.0.0.1', 'http://', 'http:///',
		'http://127.0.0.1/api', 'http://127.0.0.1?x=1', 'http://127.0.0.1#f', 'http://u@127.0.0.1',
		'http://127.0.0.1 x'] {
		new_upstream(url, UpstreamOptions{}) or { continue }
		assert false, url
	}
	for o in [UpstreamOptions{
		max_conns: 0
	}, UpstreamOptions{
		max_queue: -1
	}, UpstreamOptions{
		max_reply: 0
	}] {
		new_upstream('http://127.0.0.1:9', o) or { continue }
		assert false, '${o}'
	}
}
```

**Verify**: `v test engine/upstream_test.v` → 2 tests pass.

### Step 2: Socket tests (Linux)

Append to `engine/client_linux_test.v`:

```v
// Past max_conns and max_queue a fetch answers .busy at once. Two workers with one
// connection each and no queue: of eight fetches at once, at most two get through.
fn test_fetch_busy_past_the_queue() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{ max_conns: 1, max_queue: 0 },
		false)
	defer {
		stop.request()
	}
	ch := chan string{cap: 8}
	for _ in 0 .. 8 {
		spawn fn [front, ch] () {
			mut c := dial(front)
			mut r := Reader{}
			st, body := get(mut c, mut r, '/f/delay/400')
			ch <- '${st} ${body}'
			c.close() or {}
		}()
	}
	mut busy := 0
	mut ok := 0
	for _ in 0 .. 8 {
		got := <-ch
		if got == '599 busy' {
			busy++
		} else if got == '200 400' {
			ok++
		} else {
			assert false, got
		}
	}
	assert ok >= 1 && ok <= 2 && busy >= 6, '${ok} ok, ${busy} busy'
}

// A fetch that never got a connection times out in the queue, on its own deadline.
fn test_queued_fetch_times_out() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{
		max_conns: 1
		timeout:   time.second
	}, false)
	defer {
		stop.request()
	}
	t0 := time.sys_mono_now()
	ch := chan string{cap: 6}
	for _ in 0 .. 6 {
		spawn fn [front, ch] () {
			mut c := dial(front)
			mut r := Reader{}
			st, body := get(mut c, mut r, '/f/delay/3000')
			ch <- '${st} ${body}'
			c.close() or {}
		}()
	}
	for _ in 0 .. 6 {
		got := <-ch
		assert got == '599 timeout', got
	}
	// in flight or queued, each answered about a second in (the sweep runs once a
	// second), none after the upstream's three
	assert time.sys_mono_now() - t0 < 2900 * u64(time.millisecond)
}

fn script_ordinal(n int) (string, bool) {
	return 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n${n}', false
}

// A pooled connection idle past idle_timeout is closed: the next fetch opens a new
// one, where the scripted upstream counts from 1 again.
fn test_idle_peer_is_closed() {
	front, mut stop := start_front(raw_upstream(script_ordinal), UpstreamOptions{
		idle_timeout: time.second
	}, false)
	defer {
		stop.request()
	}
	mut c := dial(front)
	mut r := Reader{}
	_, a := get(mut c, mut r, '/f/x')
	_, b := get(mut c, mut r, '/f/x')
	assert a == '1' && b == '2', '${a} ${b}' // the second reused the connection
	time.sleep(2500 * time.millisecond)
	_, d := get(mut c, mut r, '/f/x')
	assert d == '1', d
	c.close() or {}
}

// A client that leaves while its fetch is out costs nothing: the reply is dropped
// and the server and its pool go on.
fn test_client_gone_mid_fetch() {
	up, mut up_stop := start(Options{})
	defer {
		up_stop.request()
	}
	front, mut stop := start_front(up, UpstreamOptions{ max_conns: 1 }, false)
	defer {
		stop.request()
	}
	for _ in 0 .. 4 {
		mut c := dial(front)
		c.write_string('GET /f/delay/200 HTTP/1.1\r\nHost: x\r\n\r\n') or { panic(err) }
		c.close() or {}
	}
	time.sleep(500 * time.millisecond)
	for i in 0 .. 8 {
		mut c := dial(front)
		mut r := Reader{}
		st, body := get(mut c, mut r, '/f/p/ok${i}')
		assert st == 200 && body == '/p/ok${i}', body
		c.close() or {}
	}
}
```

If a snippet does not compile as written, make the smallest change that keeps its
meaning and every assertion (they were written against the code without compiling).

**Verify** (Linux): `v test engine/client_linux_test.v` → all pass. Then run it
**five times in a row**:
`for i in 1 2 3 4 5; do v test engine/client_linux_test.v || break; done` → five
passes. A test that fails once in five is flaky: see STOP conditions.

### Step 3: Format and full suite

**Verify**:
- `v fmt -w engine/upstream_test.v engine/client_linux_test.v && v fmt -verify .` → exit 0
- `v test http1/ http2/ jsonenc/ router/ engine/ tests/` → all pass

## Test plan

Six new tests: `test_new_upstream_accepts`, `test_new_upstream_refuses` (portable,
new file), `test_fetch_busy_past_the_queue`, `test_queued_fetch_times_out`,
`test_idle_peer_is_closed`, `test_client_gone_mid_fetch` (Linux, modelled on
`test_fetch_queues_past_max_conns` and `test_fetch_retries_a_pooled_connection_once`
in the same file). Together they add about 5 s to the file's run time (two sleeps and
a one-second timeout).

## Done criteria

- [ ] `engine/upstream_test.v` exists; `v test engine/upstream_test.v` exits 0
- [ ] `grep -c "^fn test_" engine/client_linux_test.v` is 4 higher than before this plan
- [ ] On Linux: `v test engine/client_linux_test.v` exits 0 five times in a row
- [ ] `v test http1/ http2/ jsonenc/ router/ engine/ tests/` exits 0; `v fmt -verify .` exits 0
- [ ] `git status --short` lists only `engine/upstream_test.v`, `engine/client_linux_test.v` (plus `plans/README.md`)
- [ ] `git diff --stat` shows no non-test file changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- A helper named in "Current state" is missing or has another signature.
- A new test fails and the reason is the production code's behaviour, not the test
  (for example `.busy` is never answered, or the third fetch in
  `test_idle_peer_is_closed` answers `3`). Do not change the assertion to match:
  report the test, the expected and the actual value. That is a real finding.
- A new test passes sometimes and fails sometimes over the five runs and one timing
  adjustment (longer delay, more clients) does not make it stable. Report it; do not
  add retries or widen assertions until it cannot fail.
- `test_new_upstream_accepts` fails on `'http://127.0.0.1/'` because the machine has
  nothing to resolve a literal address with: remove only that case and say so.
- You feel the need to touch a non-test file.

## Maintenance notes

- These tests pin timing-related behaviour with generous margins (the sweep's
  one-second resolution). If the sweep interval or the timeout resolution changes,
  `test_queued_fetch_times_out` and `test_idle_peer_is_closed` need new numbers.
- `test_fetch_busy_past_the_queue` depends on the test server running 2 workers
  (`serve_on` sets `workers: 2`). If that changes, the `ok <= 2 && busy >= 6` bound
  changes with it.
- Not covered, deliberately: the byte bound on the queue from plan 003 (needs
  megabyte requests), IPv6 upstream URLs (CI runners without IPv6), and `App.upstream`
  in `viltrum.v` (a thin wrapper over `new_upstream`).
