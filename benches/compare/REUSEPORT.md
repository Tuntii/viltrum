# PR6 — Multi-accept / `SO_REUSEPORT` experiment

| | |
|--|--|
| **Issue** | [#22](https://github.com/Tuntii/viltrum/issues/22) (epic [#16](https://github.com/Tuntii/viltrum/issues/16)) |
| **Date** | 2026-08-05 |
| **Machine** | CachyOS Linux, Ryzen 7 4800H (16 thr), ~14 GiB |
| **Tool** | oha 1.15.0, Viltrum `-prod` |
| **Reproduce** | `bash benches/compare/run_reuseport_exp.sh` |

## What was measured

Optional `ServerOptions.accept_workers` (default **1**):

- `1` — existing single `net.listen_tcp` accept loop (production default)
- `N>1` — **Linux only**: `N` listeners with `SO_REUSEPORT` on the same address, each running `accept_loop` (non-Linux falls back to 1)

## Results (this laptop)

### Keep-alive sustained (epic gate shapes)

| accept_workers | E GET 10s c=50 | F GET 10s c=100 | Success |
|---------------:|---------------:|----------------:|--------:|
| 1 | ~95k | ~89k | 100% |
| 2 | ~98k | ~92k | 100% |
| 4 | ~99k | ~85k | 100% |
| 8 | ~106k | ~93k | 100% |

Headline: multi-listener is **flat to ~+10%** on E within laptop noise; F is non-monotonic. **Not** a league-bar move vs Axum (~180k+ on E).

### Dial storm (scenario B style)

| accept_workers | GET n=10k c=500 | Success |
|---------------:|----------------:|--------:|
| 1 | ~7.8k req/s | 100% |
| 8 | ~50k req/s | 100% |

Here multi-listener helps a lot: accept is the bottleneck under concurrent dials, not keep-alive parse/write.

## Decision (default)

**Keep `accept_workers = 1` as the default.**

| Reason | |
|--------|--|
| Epic gate (E/F keep-alive) | No clear, reliable win vs single accept |
| Complexity | Extra SO_REUSEPORT path, signal close-all, Linux-only |
| Correctness surface | More accept loops share `max_conns` / handler; fine, but more moving parts |
| When to opt in | High connection-churn / dial-storm deployments on Linux |

Opt-in:

```v
app.server_options(viltrum.ServerOptions{
	accept_workers: 4 // Linux SO_REUSEPORT multi-listener
})
```

## Non-goals for this PR

- Changing default production listen path
- TLS multi-listener (cleartext experiment only)
- Guaranteeing multi-hundred-k RPS
