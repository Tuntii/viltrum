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

No access logs. Viltrum: `recover` on, `handle_signals: false`.

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
| **Date** | 2026-07-29 |
| **Viltrum** | v0.7.0 (main) |
| **Peer** | release + LTO |
| **Machine** | CachyOS, Ryzen 7 4800H (16 thr), ~14 GiB |
| **oha** | 1.15.0 |
| **Success** | 100% both sides all scenarios |

### req/s (higher is better)

| Scenario | Viltrum | Peer | Peer / Viltrum |
|----------|--------:|-----:|---------------:|
| A GET `/` n=10k c=100 | ~61k | ~162k | ~2.6× |
| D GET `/` n=50k c=50 | ~82k | ~200k | ~2.4× |
| E GET `/` 10s c=50 | ~85k | ~202k | ~2.4× |
| F GET `/` 10s c=100 | ~71k | ~192k | ~2.7× |
| C POST `/echo` n=5k c=100 | ~54k | ~153k | ~2.8× |

**Headline (honest):** on this laptop, cleartext `GET /` sustains roughly **~70–85k req/s** for Viltrum and **~190–200k req/s** for the peer at moderate concurrency. Not a lab guarantee; re-run after code changes.

### Latency sketch (scenario E, 10s c=50)

| | avg | p50 | p99 |
|--|----:|----:|----:|
| Viltrum | ~0.58 ms | ~0.48 ms | ~2.8 ms |
| Peer | ~0.24 ms | ~0.20 ms | ~0.84 ms |

---

## How to read this

- **Fair-ish:** same client, same routes, loopback, no TLS, release/`-prod`.
- **What this measures:** raw accept + parse + tiny handler + write. Not app logic, not WS, not TLS.
- **Not a product claim** that every deployment hits these numbers.

WS / WSS peer stacks are a separate script (not this folder).
