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
```

Needs: `v`, `cargo`, `oha`, `curl`.

---

## Latest run (this laptop)

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

**Headline (honest):** on this laptop, cleartext `GET /` sustains roughly **~90–100k req/s** for Viltrum and **~190–225k req/s** for the peer at moderate concurrency. Peer ~**2×**. Not a lab guarantee; re-run after code changes.

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
