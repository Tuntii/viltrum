# fast: viltrum speed per commit

Every first-parent commit on `main` since `v1.0.0` is measured on hostlab and shown at
**https://v.rustapi.cloud/fast/**. Inspired by [fast.vlang.io](https://fast.vlang.io/).
Release commits (`chore(release): …`) only bump the version, so they are not measured; their version is shown
as a badge on the commit before them.

## What is measured

Three scenarios, with the same handlers as viltrum's HttpArena entry (`server.v`):

| Scenario | Request |
|----------|---------|
| baseline | `GET /baseline11?a=1&b=2` |
| json | `GET /json/50?m=1`, `Accept-Encoding: gzip` (jsonenc + the gzip middleware) |
| pipelined | `GET /pipeline`, 16 requests per write |

- **Instructions per request (the headline number).** The server runs under callgrind with one worker
  (`VILTRUM_WORKERS=1`) pinned to one CPU. The load client warms up, then the counters are zeroed, a fixed number
  of requests goes over one keep-alive connection (baseline and pipelined 20 000, json 2 000), and the total Ir
  is divided by that count. One connection keeps epoll batching, which depends on timing, out of the number.
  Two runs of the same commit give the same values to the instruction.
- **rps ≈.** Four workers on CPUs 0-3, the client on CPUs 4-7 with 64 connections, the median of three 3 s
  runs. hostlab is a shared VM, so this swings about ±10% between runs. Read it as a rough size.

`server.v` uses only API that viltrum has had since `v1.0.0`, so one source builds at every measured commit.
The server is built with V 0.5.2 (the version CI pins) and `-prod`. A commit that does not build shows as
`build failed`.

## The SETUP rule

Ir/request depends on more than viltrum: on `server.v`, `load.c`, the request counts and flags in
`measure.sh`, the V version, the dataset and the machine. **Any PR that changes one of these bumps `SETUP`.**
A new `SETUP` makes hostlab measure every commit again, in the background. Until that re-run covers all of
them, the page keeps showing the previous setup, so the chart never mixes two setups.

## Files

| File | Role |
|------|------|
| `server.v` | the bench server (`FAST_ADDR`, `FAST_DATA`) |
| `load.c` | keep-alive load client, our own (`load HOST PORT PATH [-c] [-p] [-n \| -d] [-H]`) |
| `measure.sh` | one commit → one JSON line (`ok`, `build_failed` or `run_failed`) |
| `results.py` | which commits to measure, the result store, what gets published; `test_results.py` |
| `run.sh` | the timer's entry point: fetch, measure what is missing, publish after each commit |
| `page/` | `index.html` + `fast.js` (`node --test page/fast_test.mjs`); `sample.json` is a fixture |
| `smoke.sh` | builds both binaries against a viltrum and checks every scenario answers |
| `deploy/` | systemd units and the nginx locations used on hostlab |

## hostlab

- `/opt/viltrum-fast/`: `repo/` (a clone; `run.sh` checks out `origin/main` and runs from it), `data/dataset.json`
  (HttpArena's file at commit `25f5f411dab3451380d1f93069e8ceac67d6d97b`, not committed here), `store.json`
  (every result of every setup), `www/` (what nginx serves), `work/` (scratch builds), `run.lock`.
- `viltrum-fast.timer` starts `viltrum-fast.service` every 5 minutes; a run that finds the lock held exits.
  `nice`/`ionice` keep it behind hostlab's live services. The bench server listens on 127.0.0.1:28090 only.
- nginx: two `location` blocks in `sites-available/v.rustapi.cloud.conf` (`deploy/nginx-fast.conf`).
- Packages installed for this: `valgrind`, which also pulled in `gdb`, `libc6-dbg`, `libc6-i386`,
  `libbabeltrace1`, `libboost-regex1.74.0`, `libdebuginfod-common`, `libdebuginfod1`, `libipt2`,
  `libsource-highlight-common` and `libsource-highlight4v5`.

Useful commands:

```sh
systemctl start viltrum-fast.service       # run now (oneshot; a backfill takes hours)
journalctl -u viltrum-fast -f              # follow a run
python3 /opt/viltrum-fast/repo/benches/fast/results.py pending --repo /opt/viltrum-fast/repo \
  --results /opt/viltrum-fast/store.json --setup "$(cat /opt/viltrum-fast/repo/benches/fast/SETUP)"
```
