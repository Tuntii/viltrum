# Conn worker pool spike (blocking I/O)

| | |
|--|--|
| **Date** | 2026-08-05 |
| **Goal** | Move keep-alive E toward ~120k without a reactor |
| **Flag** | `ServerOptions.conn_workers` (default **0** = spawn-per-conn) |
| **Reproduce** | `bash benches/compare/run_conn_pool_exp.sh` |

## Design

```text
conn_workers == 0:  accept → spawn handle_conn   (production default)
conn_workers == N:  accept → chan Conn → N workers run handle_conn
```

Keep-alive stays on the worker that owns the Conn. Hijack/WS still run inside `handle_conn` (same as spawn path). TLS uses the same `dispatch_conn`.

## Critical constraint (blocking I/O)

Each worker is **busy for the whole connection lifetime** (including idle `read` between keep-alive requests). So:

```text
effective concurrent connections ≤ conn_workers
```

If `conn_workers < client concurrency` (e.g. 8 workers, oha `-c 50`), surplus Conns queue, accept backpressures, **RPS drops hard**.

This is **not** a Tokio-style pool (evented; one worker many conns). It is a **fixed set of blocking connection handlers**.

## Results (this laptop, oha, 100% success, 3-run median)

Machine: CachyOS, Ryzen 7 4800H, 16 thr. Fresh OUT_DIR.

| conn_workers | E median (10s c=50) | F median (10s c=100) | vs spawn E |
|-------------:|--------------------:|---------------------:|-----------:|
| **0** (spawn) | **~102k** | **~90k** | baseline |
| 8 | ~70k (earlier run) | ~70k | **regress** (starvation) |
| **64** | **~108k** | **~100k** | **~+6% / +11%** |
| 128 | ~102k | ~100k | flat / F +11% |

Raw (clean run):

| mode | E runs | F runs |
|------|--------|--------|
| 0 | 105.5k, 101.1k, 102.0k | 96.1k, 89.9k, 89.0k |
| 64 | 111.6k, 107.1k, 108.4k | 100.1k, 99.5k, 99.9k |
| 128 | 101.9k, 111.7k, 98.5k | 106.0k, 96.8k, 99.6k |

## Decision

| Question | Answer |
|----------|--------|
| Default change? | **No** — stay at `conn_workers = 0` |
| Productize as recommended? | **No** — E gain ~6% (below ~15% bar); not ~120k |
| Keep code? | **Yes** — opt-in experiment; documents the constraint |
| Path to 120k? | Not this model alone. Next: real CPU profile (`perf`), then header/map cost or async I/O epic |

## Opt-in

```v
app.server_options(viltrum.ServerOptions{
	conn_workers: 64 // ≥ expected concurrent connections
})
```

## What we learned

1. **Spawn-per-conn is the correct default** for blocking `read`/`write`.
2. Undersized pools are worse than spawn.
3. Oversized pools ≈ spawn + channel overhead (sometimes a small win from less spawn churn).
4. Tokio’s advantage is **not** “N workers” in the abstract — it is **non-blocking multiplexing**.
