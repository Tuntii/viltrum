# Peer HTTP benchmark (cleartext)

Same machine, same load client ([oha](https://github.com/hatoo/oha)), same handler shape:

| Route | Behavior |
|-------|----------|
| `GET /` | body `ok` |
| `POST /echo` | JSON `{"title":…}` → `{"t":…}` |

| Server | Build | Port |
|--------|--------|------|
| **Viltrum** | `v -prod` | `127.0.0.1:18099` |
| **Peer** | release binary under `axum/` | `127.0.0.1:18098` |

No access logs. Viltrum: `recover` on, `handle_signals: false`, **`accept_workers: 1`** (default).

```bash
bash benches/compare/run_vs_axum.sh
# raw oha dumps: /tmp/viltrum-vs-axum/

# PR6 experiment: single vs SO_REUSEPORT multi-listener (Viltrum only)
bash benches/compare/run_reuseport_exp.sh
# see REUSEPORT.md — default remains accept_workers=1

# Conn worker-pool spike (blocking I/O): spawn vs fixed pool
bash benches/compare/run_conn_pool_exp.sh
# see CONN_POOL.md — default remains conn_workers=0

# Epoll reactor spike (Linux): ServerOptions.use_epoll — see REACTOR.md (default off)

# Runtime scheduler A/B (measured 2026-09-25): no default change
bash benches/compare/run_sched_exp.sh
# see SCHEDULER.md — V spawn has no thread cap; accept_workers=8 missed the 15% bar

# Multi-core epoll vs the SO_RCVTIMEO spawn path (measured 2026-09-25)
bash benches/compare/run_hotpath_exp.sh
# see CORES.md — epoll_cores=16 E +0.3% with recover; default stays spawn
```

Needs: `v`, `cargo`, `oha`, `curl`.

---

## Latest run (this laptop)

| | |
|--|--|
| **Date** | 2026-09-25 |
| **Viltrum** | v0.12.1 (`-prod`, spawn, `recover` on) |
| **Peer** | same Axum release binary |
| **Machine** | CachyOS, Ryzen 7 4800H (16 thr) |
| **oha** | 1.15.0 |
| **Runs** | E and F, 3 each, median. Success 100% |

| Scenario | Viltrum | Peer | Peer / Viltrum |
|----------|--------:|-----:|---------------:|
| **E GET `/` 10s c=50** | **216785** | **220973** | **1.02×** |
| F GET `/` 10s c=100 | 193848 | 246777 | 1.27× |

Full note: [RESULTS.md](../RESULTS.md). The table below is the 2026-08-05 lock, kept so the old ratio is not rewritten.

## 2026-08-05 lock

| | |
|--|--|
| **Date** | 2026-08-05 |
| **Viltrum** | v0.7.6 (main after PR1–PR6) |
| **Peer** | release + LTO |
| **Machine** | CachyOS, Ryzen 7 4800H (16 thr), ~14 GiB |
| **oha** | 1.15.0 |
| **Success** | 100% both sides all scenarios |

### req/s (higher is better)

| Scenario | Viltrum | Peer | Peer / Viltrum |
|----------|--------:|-----:|---------------:|
| A GET `/` n=10k c=100 | ~82k | ~209k | ~2.5× |
| D GET `/` n=50k c=50 | ~102k | ~199k | ~1.9× |
| **E GET `/` 10s c=50** | **~98k** | **~191k** | **~1.9×** |
| F GET `/` 10s c=100 | ~91k | ~225k | ~2.5× |
| C POST `/echo` n=5k c=100 | ~72k | ~167k | ~2.3× |

**August headline:** cleartext `GET /` was roughly **~90–100k req/s** for Viltrum and **~190–225k req/s** for the peer. Peer ~**2×**. Superseded by the 2026-09-25 lock above.

### Latency sketch (scenario E, 10s c=50)

| | avg | p50 | p99 |
|--|----:|----:|----:|
| Viltrum | ~0.50 ms | ~0.41 ms | ~2.4 ms |
| Peer | ~0.26 ms | ~0.21 ms | ~0.94 ms |

### vs PR1 baseline (2026-07-29)

| | Viltrum E | Peer E |
|--|----------:|-------:|
| PR1 lock | ~85k | ~202k |
| Now (PR1–PR6) | ~98k | ~191k |

Absolute Viltrum ~**+15%** on E; peer ratio improved slightly (~2.4× → ~1.9×) partly because peer also moved run-to-run.

### League bar

Epic #16 asked for E ≥ **~150k** or ≥ **~0.75×** peer. **Neither met.** Documented ceiling: see [RESULTS.md](../RESULTS.md) and epic closeout (PR7).

---

## How to read this

- **Fair-ish:** same client, same routes, loopback, no TLS, release/`-prod`.
- **What this measures:** raw accept + parse + tiny handler + write. Not app logic, not WS, not TLS.
- **Not a product claim** that every deployment hits these numbers.
- **Remaining cost** is mostly below the HTTP library (V runtime, per-conn spawn, OS `accept`/`read`/`write`) after PR2–PR5 removed the obvious double materialization and string serialize path.

WS / WSS peer stacks are a separate script (not this folder).
