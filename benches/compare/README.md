# Viltrum vs Axum (HTTP, cleartext)

Same machine, same load client ([oha](https://github.com/hatoo/oha)), same handler shape:

| Route | Behavior |
|-------|----------|
| `GET /` | body `ok` |
| `POST /echo` | JSON `{"title":…}` → `{"t":…}` |

| Server | Build | Port |
|--------|--------|------|
| **Viltrum** | `v -prod` | `127.0.0.1:18099` |
| **Axum** | `cargo build --release` (LTO) | `127.0.0.1:18098` |

No access logs. Viltrum: `recover` on, `handle_signals: false`.

```bash
bash benches/compare/run_vs_axum.sh
# raw oha dumps: /tmp/viltrum-vs-axum/
```

Needs: `v`, `cargo`, `oha`, `curl`.

---

## Latest run (this laptop)

| | |
|--|--|
| **Date** | 2026-07-29 |
| **Viltrum** | v0.7.0 (main) |
| **Axum** | 0.8.x + tokio multi-thread |
| **Machine** | CachyOS, Ryzen 7 4800H (16 thr), ~14 GiB |
| **oha** | 1.15.0 |
| **Success** | 100% both sides all scenarios |

### req/s (higher is better)

| Scenario | Viltrum | Axum | Axum / Viltrum |
|----------|--------:|-----:|---------------:|
| A GET `/` n=10k c=100 | ~61k | ~162k | ~2.6× |
| D GET `/` n=50k c=50 | ~82k | ~200k | ~2.4× |
| E GET `/` 10s c=50 | ~85k | ~202k | ~2.4× |
| F GET `/` 10s c=100 | ~71k | ~192k | ~2.7× |
| C POST `/echo` n=5k c=100 | ~54k | ~153k | ~2.8× |

**Headline (honest):** on this laptop, cleartext `GET /` sustains roughly **~70–85k req/s** for Viltrum and **~190–200k req/s** for Axum at moderate concurrency. Axum is about **2.4–2.8×** higher here. Not a lab guarantee; re-run after code changes.

### Latency sketch (scenario E, 10s c=50)

| | avg | p50 | p99 |
|--|----:|----:|----:|
| Viltrum | ~0.58 ms | ~0.48 ms | ~2.8 ms |
| Axum | ~0.24 ms | ~0.20 ms | ~0.84 ms |

---

## How to read this

- **Fair-ish:** same client, same routes, loopback, no TLS, release/`-prod`.
- **Not claiming:** Axum is “better framework” in product terms, or that Viltrum should match Tokio’s runtime.
- **Why Axum is faster (expected):** mature multi-thread async runtime, years of HTTP/1.1 edge polish, LTO’d Rust codegen. Viltrum is a young own-stack engine in V.
- **What this measures:** raw accept + parse + tiny handler + write. Not app logic, not WS, not TLS.

WS / WSS vs tungstenite-style stacks is a separate script (not this folder).
