# Plan 005: The docs stop contradicting the code, and the repo has an AGENTS.md

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat acb27f3..HEAD -- README.md ROADMAP.md examples/README.md docs/README.md docs/upgrade.md docs/deploy.md docs/client.md docs/design/v0.6-tls-wss.md SECURITY.md .github/ISSUE_TEMPLATE/bug_report.md .github/pull_request_template.md`
> Plans 002 and 003 add sentences to `docs/client.md`; that is expected. For any other
> change, compare the quoted "Current state" lines against the live files; if a quoted
> line is gone or already fixed, skip that one edit and note it in your report.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (text only; two obsolete files deleted)
- **Depends on**: none
- **Category**: docs / dx
- **Planned at**: commit `acb27f3`, 2026-11-10 (branch `feat/http-client`)

## Why this matters

The branch that adds the HTTP client (`c.fetch`) still says in three places that
Viltrum has no HTTP client. A page mirrored to the public wiki documents an API
(`app.upgrade`, `c.write_all`) that does not exist in the code and says it "returns
later", against the roadmap. The README calls the stop "graceful" while the engine
closes every connection within a second without sending what is pending. Each of these
makes a reader — or a coding agent — trust the wrong thing. Separately, the repo has
no `AGENTS.md`: the rules an agent must know to work here (no allocation on the
request path, which tests run where, how to mark cold code, how not to corrupt V
files) are spread over CI config, scripts and old plans.

## Current state

Quoted lines are what the files say at the planned commit.

1. `README.md:131`
   `Not on the 1.x core yet: an HTTP client, and serving off Linux.`
   — but `README.md:125` lists `c.fetch(upstream, method, target, cb, arg)` in the
   feature table, and `viltrum.v` has `pub fn (mut app App) upstream(...)`.
2. `README.md:203-204`
   `Open work is on the [project board](https://github.com/users/Tuntii/projects/3): the HTTP/2 share of the`
   `per-connection memory work, an async HTTP client, WebSocket over HTTP/2, and metrics. Each feature gets its own`
   — the HTTP/2 memory work is done (`ROADMAP.md`, Phase 8, all boxes ticked) and the
   client's first part is done (Phase 9a ticked; 9b, `https://` upstreams, is open).
3. `README.md:114` ends the Engine row with `graceful SIGINT/SIGTERM`.
   The code (`engine/worker_linux.c.v:146-152`) closes every open connection when the
   worker stops; `docs/connection.md:29` says it correctly:
   `- SIGINT/SIGTERM stop accepting; open connections are closed within a second.`
4. `ROADMAP.md:62`
   `| Generic upgrade, HTTP client | **not on the 1.0 core yet** (they existed on 0.x) |`
   — while `ROADMAP.md:173` ticks Phase 9a.
5. `examples/README.md:38`
   `The HTTP client is not on the 1.x core yet; see the README.`
6. `docs/README.md:3`
   `Viltrum 1.x is a small HTTP/1.1 framework for [V](https://vlang.io) on a zero-allocation core: one`
   — HTTP/2, WebSocket and TLS shipped. And `docs/README.md:27` lists examples as
   `(`hello`, `rest`, `features`, `https`, `ws_chat`)` without `sse`, which exists
   (`examples/sse/`).
7. `docs/README.md:33-35`
   ```
   ## v0.13 reference (not 1.x)

   [upgrade.md](./upgrade.md) describes the v0.13 upgrade API and is kept for reference only.
   ```
   `docs/upgrade.md:1` says `> **Not in 1.0.** This page describes v0.13. The feature returns on the 1.0 core later.`
   and documents `app.upgrade`, `c.write_all`, `Conn`, `Request`,
   `switching_protocols` — none of which exist in the 1.x code. `ROADMAP.md:104-105`
   says "generic hijack stays out until something needs it". `docs/` is mirrored to the
   GitHub wiki. Nothing else links to `upgrade.md`.
   `docs/design/v0.6-tls-wss.md` is the 0.x TLS design, replaced by
   `docs/design/1.x-tls.md`; nothing links to it.
8. `docs/deploy.md:69-70`
   ```
   - One process, one listen address (multi-listener is backlog).
   - Graceful stop: SIGINT/SIGTERM closes the listener; existing conns are not given a long drain window in 0.3.x.
   ```
   — `app.serve` takes several listeners since 1.2.0 (README feature table, TLS row),
   and "0.3.x" is three major lines old.
9. `SECURITY.md:15-20` ("In scope") names HTTP, multipart, WebSocket and
   `listen_tls`, but not HTTP/2 and HPACK, the in-house TLS 1.3 records and handshake,
   or replies from upstreams (`http1/reply.v`), all of which parse untrusted bytes.
10. `.github/ISSUE_TEMPLATE/bug_report.md`: ``**Versions:** Viltrum `v0.x.y` / commit, ...``
11. `.github/pull_request_template.md:4`
    ``- [ ] `v test http1/ jsonenc/ router/ engine/ tests/` passes, `bash scripts/hotpath_lint.sh` clean``
    — `http2/` is missing; CI runs `v test http2/` too.
12. `docs/client.md` — the main example forwards the client's path:
    `c.fetch(users, .get, c.path(), on_user, 0)` on the route `/users/:id`. A `:param`
    matches any one segment, including `..`, and `c.path()` is the path as the client
    sent it (still percent-encoded). There is no note that the upstream may normalise
    `/users/..` to `/`.
13. There is no `AGENTS.md` or `CLAUDE.md` in the repo root.

Facts for `AGENTS.md` (all verified in the repo at the planned commit):

- Checks CI runs (`.github/workflows/ci.yml`): `v fmt -verify .`;
  `v test http1/`, `http2/`, `jsonenc/`, `router/`, `engine/`, `tests/`;
  `v -d viltrum_debug test router/ engine/ tests/`;
  `v -cc gcc test engine/aesgcm_linux_test.v engine/tls13_linux_test.v engine/tls_linux_test.v engine/hs13_linux_test.v`;
  `v -cc gcc test http1/deflate_test.v jsonenc/`; `bash scripts/hotpath_lint.sh`;
  `bash scripts/gcpin_check.sh`; building every example; five fuzz runs with
  `VILTRUM_FUZZ_ITERS=500000`.
- V 0.5.2 is the pinned compiler; CI also tests V master.
- `bash scripts/install.sh` links the checkout as `~/.vmodules/viltrum`.
- Files named `*_linux.c.v` and `*_linux_test.v` build and run on Linux only. The
  engine serves on Linux only (epoll). On macOS and Windows the other unit tests run.
- `scripts/hotpath_lint.sh` fails on `${`, `.str()`, `.split(`, `.to_lower(`,
  `.to_upper(`, `.trim`, `.bytestr()`, `.clone()` and slices in its listed files; a
  line opts out with a trailing `// cold: <reason>`.
- `.github/workflows/perf.yml` fails a pull request when a scenario costs more than 1%
  more callgrind instructions per request than its base; label `perf-ok` accepts a
  deliberate cost.
- Conventional Commits drive semantic-release (`docs/releasing.md`).
- `v.mod` has `dependencies: []`; `ROADMAP.md` has the principles and non-goals.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Find a phrase | `grep -rn "<phrase>" README.md ROADMAP.md docs examples` | see each step |
| Check links to a deleted file | `grep -rn "upgrade.md\|v0.6-tls-wss" --include=*.md . \| grep -v "^./CHANGELOG\|^./plans\|^./docs/superpowers"` | no output |
| V formatting untouched | `v fmt -verify .` | exit 0 (no `.v` file is edited in this plan) |

## Scope

**In scope**:

- `README.md`, `ROADMAP.md` (line 62 only), `examples/README.md`, `docs/README.md`,
  `docs/deploy.md` (the two "Process model" bullets), `docs/client.md` (one note),
  `SECURITY.md` ("In scope" list), `.github/ISSUE_TEMPLATE/bug_report.md`,
  `.github/pull_request_template.md`
- `docs/upgrade.md` (delete), `docs/design/v0.6-tls-wss.md` (delete)
- `AGENTS.md` (create), `CLAUDE.md` (create, one line)

**Out of scope**:

- Every `.v` file, script and workflow.
- `CHANGELOG.md` — generated by semantic-release; old entries may mention deleted
  files and stay as history.
- `docs/superpowers/`, `benches/` — old material, left for the maintainer to decide.
- The benchmark numbers and medal counts in `README.md` and `ROADMAP.md`.
- `ROADMAP.md` beyond line 62: it is the maintainer's product plan.
- Rewording anything not listed in "Current state".

## Git workflow

- Branch from `feat/http-client`: `advisor/005-docs-truth-pass`.
- Two commits: `docs: fix claims the code no longer matches, drop the 0.x upgrade page`
  and `docs: add AGENTS.md`.
- Do NOT push or open a PR unless told to. Do not change git config.

## Steps

### Step 1: HTTP client claims

- `README.md:131` → `Not on the 1.x core yet: `https://` upstreams for the HTTP client, and serving off Linux.`
- `README.md:203-204`: replace `the HTTP/2 share of the per-connection memory work, an async HTTP client, WebSocket over HTTP/2, and metrics.` with
  `` `https://` upstreams for the HTTP client, WebSocket over HTTP/2, and metrics. `` (re-wrap the paragraph at about 115 columns like its neighbours).
- `ROADMAP.md:62`: replace the row with two rows:
  ```
  | HTTP client: `app.upstream`, `c.fetch`, cleartext HTTP/1.1 upstreams | done (Phase 9a); `https://` upstreams open (9b) |
  | Generic upgrade | **not on the 1.0 core yet** (it existed on 0.x) |
  ```
- `examples/README.md:38` → `Calling another service from a handler (`c.fetch`) is in [docs/client.md](../docs/client.md); there is no example app for it yet.`

**Verify**: `grep -rn "HTTP client is not\|an HTTP client, and\|an async HTTP client" README.md ROADMAP.md examples docs/README.md` → no output.

### Step 2: The stop is not graceful

- `README.md:114`: replace `graceful SIGINT/SIGTERM` with
  `SIGINT/SIGTERM stop accepting and close open connections within a second`.
- `docs/deploy.md:69-70`: replace the two bullets with
  ```
  - One process; several listen addresses with `app.serve` (cleartext and TLS side by side).
  - Stop: SIGINT/SIGTERM stop accepting, and open connections are closed within a second. Responses not sent by
    then are lost (deferred ones included), so drain at the load balancer before stopping.
  ```

**Verify**: `grep -rn "graceful SIGINT\|0\.3\.x\|multi-listener is backlog" README.md docs` → no output.

### Step 3: Remove the 0.x pages, fix the docs index

- Delete `docs/upgrade.md` and `docs/design/v0.6-tls-wss.md` (`git rm`).
- `docs/README.md`: delete the section `## v0.13 reference (not 1.x)` and its
  paragraph (lines 33-35).
- `docs/README.md:3`: `Viltrum 1.x is a small HTTP/1.1 framework` →
  `Viltrum 1.x is a small HTTP framework (HTTP/1.1, HTTP/2, WebSocket)`.
- `docs/README.md:27`: add `` `sse` `` to the examples list:
  `` (`hello`, `rest`, `features`, `https`, `ws_chat`, `sse`) ``.

**Verify**: the "Check links to a deleted file" command from the table → no output.
`test ! -e docs/upgrade.md && test ! -e docs/design/v0.6-tls-wss.md && echo gone` → `gone`.

### Step 4: Templates and SECURITY scope

- `.github/pull_request_template.md:4`: `v test http1/ jsonenc/ router/ engine/ tests/`
  → `v test http1/ http2/ jsonenc/ router/ engine/ tests/`.
- `.github/ISSUE_TEMPLATE/bug_report.md`: `v0.x.y` → `v1.x.y`.
- `SECURITY.md`, "In scope" list: change the second and fourth bullets and add one:
  ```
  - Request smuggling / framing disagreements (Content-Length, Transfer-Encoding, header parsing), over HTTP/1.1 and HTTP/2
  - Crashes or panics reachable from a remote peer (HTTP/1.1, HTTP/2 and HPACK, multipart, WebSocket frames)
  - Limit bypasses (`max_body_bytes`, header size, timeouts, `max_conns`)
  - TLS: the TLS 1.3 records and handshake, certificate handling, WSS
  - The HTTP client: replies from an upstream that crash a worker, stall it, or reach another request's handler
  ```

**Verify**: `grep -n "http2/" .github/pull_request_template.md` → one match;
`grep -n "HPACK" SECURITY.md` → one match.

### Step 5: One note in `docs/client.md`

After the bullet list that follows the first example (the bullets starting
"`app.upstream(url, opts)` takes"), add this paragraph:

```
The example forwards the path the client sent. `:id` matches any one segment, `..` included, and `c.path()` is
not decoded or normalised: an upstream that resolves `/users/..` would serve `/`. When the route is meant to
limit what the upstream is asked for, build the target from what you checked (`c.param_int('id')`, an
allow-list) instead of passing `c.path()` through.
```

Check that `param_int` exists before naming it: `grep -n "pub fn (c &Ctx) param_int\|pub fn (mut c Ctx) param_int" http1/*.v`.
If there is no match, write `c.param('id')` instead.

**Verify**: `grep -n "not decoded or normalised" docs/client.md` → one match.

### Step 6: `AGENTS.md` and `CLAUDE.md`

Create `AGENTS.md` in the repo root with exactly this content:

````markdown
# Working on Viltrum (for coding agents)

Viltrum is an HTTP framework for V with its own engine: one epoll worker per CPU, HTTP/1.1, HTTP/2, WebSocket,
TLS 1.3, and an HTTP client on the same workers. Read [ROADMAP.md](ROADMAP.md) for the principles and the
non-goals before proposing a feature; each feature gets a design note in `docs/design/` first.

## Layout

| Path | What |
|------|------|
| `viltrum.v`, `middleware.v` | the public API (`App`, routes, listeners, middleware) |
| `http1/` | parser, `Ctx`, response writer, DEFLATE, WebSocket frames, files, forms, upstream replies |
| `http2/` | HPACK, Huffman, frames |
| `engine/` | the event loop (`worker_linux.c.v`), request processing, HTTP/2, TLS, the client; crypto in `*.h` |
| `router/`, `jsonenc/` | the router, the compile-time JSON encoder |
| `tests/` | app-level tests; unit tests sit beside their source as `*_test.v` |
| `benches/fast/` | the instruction-count measurement the PR perf gate uses |

## Setup and checks

```bash
bash scripts/install.sh            # links this checkout as ~/.vmodules/viltrum (import viltrum)
v fmt -verify .
v test http1/ http2/ jsonenc/ router/ engine/ tests/
v -d viltrum_debug test router/ engine/ tests/
bash scripts/hotpath_lint.sh
bash scripts/gcpin_check.sh        # Linux, slow: builds benches/httparena with -prod
```

V 0.5.2 is the pinned compiler; CI also runs the tests on V master.

`*_linux.c.v` and `*_linux_test.v` build and run on Linux only: the engine serves on epoll. On macOS and
Windows the remaining unit tests run and handlers can be exercised with `app.handle_raw`. If you cannot run
the Linux tests, say so; do not report them as passing.

## Rules that are easy to break

- **No allocation per request.** Tests run each request shape thousands of times and fail when the GC heap
  grows by a byte. In files `scripts/hotpath_lint.sh` lists, string interpolation, `.str()`, `.clone()`,
  `.bytestr()`, `.split(`, `.trim...`, `.to_lower(` and slices fail the lint. Code that truly runs off the
  request path (startup, a buffer growing once) ends its line with `// cold: <reason>`.
- **Request strings are views** into the connection's buffer, valid until the handler returns. Keep one with
  `.clone()`, in handler code only.
- **The perf gate.** A pull request fails when a measured scenario costs more than 1% more instructions per
  request than its base. A deliberate cost needs a sentence in the PR and the `perf-ok` label.
- **No third-party dependencies**, vendored or not. `v.mod` lists none. Write what is needed in the repo.
- **Do not edit `.v` files with shell heredocs, `sed` or inline scripts.** They turn the `\r`, `\n` and `\t`
  escapes inside V string and character literals into real control characters. Use a file-editing tool.
- **Docs follow the code.** A change to the public API or to what goes on the wire updates the matching file
  in `docs/` in the same change.
- **Misuse is quiet in release builds** and panics under `-d viltrum_debug`; V cannot recover from a panic,
  so library code must not panic on input from the network.

## Commits

Conventional Commits (`feat`, `fix`, `perf`, `docs`, `test`, `ci`, `chore`, `refactor`), with a scope where it
helps: `fix(h2): ...`. `feat` and `fix` cut a release through semantic-release ([docs/releasing.md](docs/releasing.md)),
so use them for changes users can see, and not for anything else.
````

Create `CLAUDE.md` in the repo root with the single line:

```
See [AGENTS.md](AGENTS.md).
```

**Verify**: `test -f AGENTS.md && test -f CLAUDE.md && echo ok` → `ok`.
`grep -c "" CLAUDE.md` → `1`.

### Step 7: Final check

**Verify**:
- `git status --short` → only the in-scope files (2 deleted, 2 created, 9 modified at most).
- `git diff --stat -- '*.v' '*.sh' '*.yml'` → empty.
- `v fmt -verify .` → exit 0.

## Test plan

No code changes, so no new tests. The greps in each step are the regression checks.

## Done criteria

- [ ] `grep -rn "HTTP client is not\|an HTTP client, and\|an async HTTP client\|graceful SIGINT\|0\.3\.x" README.md ROADMAP.md examples docs` → no output
- [ ] `docs/upgrade.md` and `docs/design/v0.6-tls-wss.md` do not exist; no Markdown file outside `CHANGELOG.md`, `plans/` and `docs/superpowers/` links to them
- [ ] `grep -n "http2/" .github/pull_request_template.md` → one match
- [ ] `AGENTS.md` and `CLAUDE.md` exist at the repo root
- [ ] `git diff --stat -- '*.v' '*.sh' '*.yml'` is empty
- [ ] `plans/README.md` status row updated

## STOP conditions

- A quoted line from "Current state" is not in the file and you cannot find the same
  claim elsewhere in it: skip that edit and report it (do not rewrite nearby text).
- `grep` finds a link to `docs/upgrade.md` or `docs/design/v0.6-tls-wss.md` from a file
  not listed in this plan: do not delete the target; report the linking file.
- You are about to change a benchmark number, a medal count, or a `ROADMAP.md` line
  other than 62.

## Maintenance notes

- `docs/` is copied to the GitHub wiki by hand; after this lands, the wiki's
  `upgrade` page should be removed there too. This plan cannot do that.
- `AGENTS.md` repeats the check commands from `CONTRIBUTING.md` and `ci.yml`. Plan 006
  adds `scripts/check.sh`; once it lands, point both documents at the script.
- "Graceful" was removed, not implemented. If a drain window is added to the engine
  later (flush pending responses before closing on stop), restore the word then, with
  a test.
- Reviewer: this plan deletes two tracked docs. Confirm that is wanted; the content
  stays in git history (`git show acb27f3:docs/upgrade.md`).
