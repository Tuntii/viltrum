# fast: per-commit speed page for viltrum

Date: 2026-10-30. Inspired by [fast.vlang.io](https://fast.vlang.io/), and the page says so.

## Intent

Every commit that lands on `main` gets measured, and a public page shows the numbers commit by commit, so a
regression (or a win) is visible the day it merges, not at the next HttpArena run. The user asked for "rps per
commit"; the page leads with a number that does not drift with machine noise and shows rps next to it.

## Goals

- One row per first-parent commit on `main`: short hash (linked to GitHub), date, subject, and per scenario the
  **instructions per request** (callgrind `Ir` / request) plus an **approximate rps**.
- A chart above the table: Ir/request per scenario across commits (layout "B" chosen in the mockup session).
- Changes above ±1% against the previous measured commit are colored (red = slower / more Ir, green = faster).
- History back to `v1.0.0` measured once at setup, so the chart is full on day one.
- New commits are picked up automatically within a few minutes of the push.
- Page footer: "Inspired by fast.vlang.io", link to the repo, the machine description and the method.

## Non-goals

- Not a replacement for HttpArena; no comparisons with other frameworks.
- No TLS, HTTP/2 or WebSocket scenarios in the first version (can be added later as extra columns).
- No PR measurement, only `main`.
- No alerts or bots commenting on PRs.

## Anti-goals

- Must not disturb the user's live services on hostlab (trade-journal API on 8080, demo on 3096 and 18082,
  databases, gitea). Never bind 8080/8081/8090/8095/3096/18082, never stop containers, keep load runs short.
- rps must not be presented as precise: the VM swings ±10% run to run. It is labeled "≈" and visually secondary.
- No third-party code committed to the repo (zero-deps rule). Tools installed on hostlab with apt (valgrind) are
  fine; anything committed (load client, scripts, page) is our own code. The chart is drawn with our own inline
  SVG/JS, no chart library.

## Scenarios

Same handlers as HttpArena's, so the numbers relate to the profiles we are scored on:

| Scenario | Request | What it exercises |
|----------|---------|-------------------|
| baseline | `GET /baseline11?a=1&b=2` keep-alive, one at a time per connection | parse, route, small response |
| json | `GET /json/50?m=1` with `Accept-Encoding: gzip` | jsonenc + gzip middleware (json-comp) |
| pipelined | `GET /pipeline`, 16 requests per write | batching, the pipelined path |

The bench server (`benches/fast/server.v`) uses only API that exists unchanged from `v1.0.0` to today
(`viltrum.new`, `app.get`, `c.text`, `c.json`/jsonenc, `viltrum.gzip`, `c.param_int`, `c.query_int`, `app.serve`
or whatever 1.0 had). The builder checks that one source compiles at `v1.0.0` and at `main`; if it cannot, the
script may keep a small per-range variant, but the handlers must do the same work in every variant. A commit that
does not build is recorded as `build failed` and shown as a gap.

## Method

Per commit, on hostlab:

1. `git worktree`/`git archive` the commit into a scratch dir, symlink it as `viltrum` in a private VMODULES dir,
   build the bench server with V 0.5.2 (`/root/v052/v/v -prod`), the version CI pins.
2. **Ir/request:** start the server under `valgrind --tool=callgrind` pinned to one worker (one CPU, so the count
   is per request, not split across workers), warm up, `callgrind_control -z`, send a fixed number of requests
   per scenario with our own client, `callgrind_control -d`, read total Ir, divide by the request count. This is
   the method used for HttpArena #1660; it reproduced within <1% run to run.
3. **rps ≈:** start the server normally, server `taskset -c 0-3`, client `taskset -c 4-7`, a few seconds per
   scenario, take the median of 3 short runs. Total load time per commit stays under ~30 s.
4. Append the result to `results.json` (one object per commit: hash, date, subject, per-scenario `ir`, `rps`,
   V version, status). Already-measured hashes are skipped.

**Setup version (user's decision):** Ir/request depends on the bench server, the load client, request counts, the
V version, valgrind and the OS, not only on the viltrum commit. A `SETUP` constant in `benches/fast/` (bumped by
hand in any PR that changes the method, the bench server, the client or the V version) is stored with every
result, and the skip key is (hash, setup). When `SETUP` changes, **every commit is re-measured** in the background
(oldest first, `nice`/`ionice`, a few hours on hostlab); until the new run covers all commits the page keeps
showing the previous setup's complete set, so the chart never mixes setups. The timer runs the scripts from the
`origin/main` checkout it just pulled; a script change without a `SETUP` bump is a bug the README warns about.

**Which commits (my call):** first-parent commits on `main` since `v1.0.0`, minus `chore(release): … [skip ci]`
commits (28 of 75: they only bump the version, so they would repeat the row before them). The merge a release
ships gets the version as a tag badge in its row, taken from `git tag --points-at` of the release commit.

**Dataset for `/json/50` (my call):** HttpArena's `dataset.json`, downloaded once on hostlab at a pinned
HttpArena commit into `/opt/viltrum-fast/data/` and not committed, so the json numbers line up with json-comp and
#1660. It is data, not code, so the zero-deps rule is not in play; it counts toward `SETUP` like everything else.

**Load client:** our own small C or V epoll client in `benches/fast/` (keep-alive, fixed connection count,
pipelining depth option, fixed request count or fixed duration). wrk is not installed on hostlab and must not be
vendored.

**Trigger:** a systemd timer (every 5 min) runs the script: `git fetch`, list first-parent commits on
`origin/main` not in `results.json`, measure them oldest first. A lock file prevents overlapping runs. Backfill is
the same script run once; ~75 commits since v1.0.0.

## Page

- Static `index.html` + `results.json`, built from `benches/fast/page/` in the repo, copied to the served dir by
  the script after each update.
- Served at **https://v.rustapi.cloud/fast/** (user's choice of host; the `/fast/` path is my call): a
  `location /fast/` in the existing `sites-available/v.rustapi.cloud.conf`, `alias` to the served dir. The demo
  app at `/` is untouched.
- Layout B: title "viltrum: fast", one-line subtitle (measured on hostlab, inspired by fast.vlang.io), a line chart
  of Ir/request per scenario over commits (own SVG), then the table newest first. rps column muted with "≈".
  Works at phone width, light and dark.

## Where things live

- Repo: `benches/fast/` (server.v, client, run.sh, page/, README.md with the method). Changes go through PRs.
- hostlab: `/opt/viltrum-fast/` (repo clone that the timer pulls, scratch builds, `results.json`, served dir),
  systemd `viltrum-fast.service` + `.timer`. Installed packages: `valgrind` (and `libc6-dbg` if callgrind needs
  it); record exactly what is installed. Never `apt-get autoremove`.

## Left to the builder

- C vs V for the load client; exact request counts and warmup lengths (keep callgrind runs to a few minutes per
  commit total).
- results.json schema details, chart styling, how gaps (build failed) render.
- Whether the timer runs as root or a dedicated user (DynamicUser is used for the demo; valgrind + git need a
  writable state dir).

## Calls I made (user to check)

- Ir/request is the headline number, rps ≈ is secondary (user: "o mantıkta").
- Three scenarios (baseline, json, pipelined); no TLS/H2/WS in v1.
- Backfill from v1.0.0, first-parent commits only, without the `chore(release)` commits; versions shown as badges.
- json dataset: HttpArena's file on hostlab, not committed.
- `/fast/` path on v.rustapi.cloud.
- Code lives in the repo under `benches/fast/`; hostlab runs a clone.
