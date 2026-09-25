# Runtime scheduler A/B (spawn path)

| | |
|--|--|
| **Plan** | [RUNTIME.md](./RUNTIME.md) |
| **Date** | 2026-09-25 |
| **V** | 0.5.2 `1188128` |
| **Machine** | CachyOS Linux, Ryzen 7 4800H (16 thr), ~14 GiB |
| **Tool** | oha 1.15.0, Viltrum `-prod`, same Axum release binary as the peer bench |
| **Reproduce** | `bash benches/compare/run_sched_exp.sh` |

## What was asked

One knob on the existing spawn-per-conn path. Shapes **E** (`-z 10s -c 50`) and **F** (`-z 10s -c 100`), three runs, median. No new reactor.

## Scheduler knob

V 0.5.2 `spawn` compiles to `pthread_create` + `pthread_detach` (`vlib/v/gen/c/spawn_and_go.v`). One OS thread per live connection. Nothing in that path reads a thread-pool size.

`runtime.nr_jobs()` does honor `VJOBS`. This run:

| env | `nr_jobs()` |
|-----|------------:|
| unset | 16 |
| `VJOBS=1` | 1 |
| `VJOBS=16` | 16 |

That value sizes the compiler pool, `sync.pool`, and photon `go`. Viltrum's accept loop uses `spawn`, not `go`, so `VJOBS` does not change the server.

Photon `go` is a different primitive. Its work pool only multiplexes if the sockets are photon sockets. Std `net` `read`/`write` would block a vCPU. That is a new I/O stack, which this experiment does not add.

## Fallback knob

`ServerOptions.accept_workers`, already in tree (PR6). Baseline **1** (production default). Variant **8** (the single-run peak in [REUSEPORT.md](./REUSEPORT.md)). `conn_workers` stays **0**. That pool was already measured ([CONN_POOL.md](./CONN_POOL.md)): best keep-alive E was about **+6%** at 64 workers, under the 15% bar.

## Results (this laptop, oha, 100% success, 3-run median)

| mode | E median | F median | vs spawn E |
|------|----------:|----------:|-----------:|
| `accept_workers=1` | **107.4k** | **98.7k** | baseline |
| `accept_workers=8` | **106.7k** | **95.4k** | **−0.6%** |
| Axum (same session) | **217.4k** | **226.1k** | peer ~**2.0×** on E |

Raw:

| mode | E runs | F runs |
|------|--------|--------|
| accept 1 | 104.3k, 112.0k, 107.4k | 98.7k, 99.6k, 97.8k |
| accept 8 | 106.7k, 99.0k, 109.3k | 89.8k, 95.4k, 96.4k |
| Axum | 217.4k, 224.8k, 215.9k | 226.1k, 260.8k, 151.0k |

Axum F's third run dipped to ~151k. The median is the middle sample. Laptop variance is real. It does not change the Viltrum comparison: accept 8 is flat on E and slightly down on F.

Viltrum E / Axum E ≈ **0.49×**. The old league bar (E ≥ ~150k or ≥ ~0.75× peer) is still not met. Same ceiling as [RESULTS.md](../RESULTS.md), re-measured on current `main` (v0.11.0 tree).

`oha` prints a handful of `aborted due to deadline` at the end of each `-z 10s` window. Success rate stayed 100% with status 200. Same client behavior as the earlier benches.

## Decision

| Question | Answer |
|----------|--------|
| ≥15% keep-alive E? | **No** (−0.6%) |
| Default change? | **No** — stay at `accept_workers = 1`, `conn_workers = 0`, `use_epoll = false` |
| Delete `accept_workers`? | **No** — existing opt-in, already documented for dial storms |
| Upgrade / WS soak for a new default? | Not required. The bar for default-on was not met. Multi-accept still calls `spawn handle_conn`, the same function as the production path. |
| Another reactor? | **No.** Epoll already regressed. This was the last planned knob. |

Opt-in, unchanged:

```v
app.server_options(viltrum.ServerOptions{
	accept_workers: 8 // Linux SO_REUSEPORT; keep-alive does not win
})
```
