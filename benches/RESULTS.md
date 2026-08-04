# Bench notes (honest)

| | |
|--|--|
| **Version** | Viltrum **v0.7.6** (`-prod` server binary) |
| **Date** | 2026-08-05 (HTTP peer re-baseline after hot-path PR1–PR6); WS table still 2026-07-23 |
| **Machine** | local CachyOS Linux (developer laptop), not a dedicated lab |
| **CPU** | AMD Ryzen 7 4800H (16 threads), ~14 GiB RAM |
| **Tools** | [oha](https://github.com/hatoo/oha) **1.15.0** (HTTP); **V first-party** masked WS load client (`benches/ws_load_client.v`) |

Handler profile: `recover` on (HTTP), **logging off**, `handle_signals: false`, cleartext only, **`accept_workers: 1`** (default).

Reproduce:

```bash
bash benches/run.sh      # HTTP
bash benches/run_ws.sh   # WebSocket echo (headline = V client)
CLIENT=python bash benches/run_ws.sh   # optional Python smoke
bash benches/soak_ws.sh  # WS multi-conn echo + close-storm (correctness)
# SOAK_SECONDS=120 bash benches/soak_ws.sh   # optional longer local soak
bash benches/compare/run_vs_axum.sh   # peer benchmark (see compare/README.md)
bash benches/compare/run_reuseport_exp.sh  # PR6 multi-listener experiment
```

---

## HTTP engine (post hot-path epic, 2026-08-05)

Locked on this laptop after PR1–PR6 (byte parse, single ownership, response builder, conn-local buffers; multi-accept measured but default off). Full peer table: [compare/README.md](./compare/README.md).

### Peer compare (oha, 100% success both sides)

| Scenario | Viltrum | Peer (Axum) | Peer / Viltrum |
|----------|--------:|------------:|---------------:|
| A GET n=10k c=100 | **~82k** | ~209k | ~2.5× |
| D GET n=50k c=50 | **~102k** | ~199k | ~1.9× |
| **E GET 10s c=50** | **~98k** | ~191k | **~1.9×** |
| F GET 10s c=100 | **~91k** | ~225k | ~2.5× |
| C POST `/echo` n=5k c=100 | **~72k** | ~167k | ~2.3× |

**Headline (honest):** cleartext `GET /` sustains roughly **~90–100k req/s** at moderate concurrency on this laptop (E/F). Peer stays ~**2×** ahead. Not a lab guarantee; laptop variance is real.

Snippet from E (10s, c=50):

```text
Success rate:  100%
Requests/sec:  ~98493
Average:       0.50 ms
p50 / p99:     0.41 ms / 2.43 ms
```

### vs PR1 lock (2026-07-29, v0.7.0)

| Scenario | PR1 Viltrum | Now | Δ (absolute) |
|----------|------------:|----:|-------------:|
| E GET 10s c=50 | ~85k | **~98k** | ~**+15%** |
| F GET 10s c=100 | ~71k | **~91k** | ~**+28%** |

### League bar (epic #16)

| Bar | Target | Result |
|-----|--------|--------|
| Absolute | E ≥ ~150k | **Not met** (~98k) |
| Relative | E ≥ ~0.75× peer | **Not met** (~0.51×) |

Honest ceiling after PR1–PR6: **own-stack cleartext sits in a ~90–110k band** on this box for keep-alive GET; remaining gap is largely **runtime / scheduler / syscall stack** (V spawn-per-conn + std `net` vs Tokio multi-thread), not a single missing clone on the HTTP path. See [HTTP_PROFILE.md](./HTTP_PROFILE.md) Decision and [compare/REUSEPORT.md](./compare/REUSEPORT.md) (dial-storm improves with opt-in multi-listener; keep-alive does not).

### Historical fixed-n (pre-epic, still useful as class-of-test)

Older 2026-07-19 shapes (v0.5.x era) for dial-storm / short burst context — not re-locked this closeout:

| Scenario | n | c | Notes |
|----------|--:|--:|-------|
| B GET `/` | 10k | 500 | Dial storm; ~8k class with `accept_workers=1`; ~50k class with workers=8 (PR6) |
| G GET `/` | — | 200 | 5s sustained, lower than E/F |

---

## WebSocket (`ws://` echo)

Server: `app.ws` echo text/binary. **Headline client: V** (`benches/ws_load_client.v`), masked frames, multi-conn via spawn. *(Table from 2026-07-23 re-baseline; not re-run in PR7.)*

| Scenario | Shape | Result (V client) | Success |
|----------|-------|------------------:|--------:|
| A single conn | 20k × 64 B text echo | **~10.0k msg/s** | 100% |
| B concurrent | 32 conn × 5k × 64 B | **~37.5k msg/s** aggregate | 100% |
| C concurrent | 100 conn × 1k × 64 B | **~34.2k msg/s** aggregate | 100% |
| D single large | 5k × 1 KiB text echo | **~4.4k msg/s** (~8.9 MiB/s rx+tx) | 100% |

Correctness: `bash benches/soak_ws.sh` (echo + close-storm). Unmasked client → close **1002** (unit tests).

**Headline (honest):** multi-conn echo sits in the **~30–40k msg/s** band on this laptop for small payloads with the V client; single-conn ~**10k msg/s**. Python client remains optional (`CLIENT=python`) and is slower on multi-conn (historical lower bound ~15–25k agg).

### Method notes

| Client | Role |
|--------|------|
| V `ws_load_client.v` | Headline throughput in `run_ws.sh` (default) |
| Python (optional) | Smoke / cross-check only |
| `soak_ws.sh` | Correctness, not throughput |

### WS write-path notes (0.5.x)

- Server frames encode into a **reused per-socket scratch buffer** (`encode_server_into`); public write APIs unchanged.
- Close-storm correctness: `WsSocket` holds `Conn` by reference (copy caused double-close under load).

---

## What this is not

- Not TechEmpower / not multi-node
- Not TLS / `wss://` / HTTP/2
- Not large-payload or slowloris stress
- Not a promise of multi-hundred-k RPS on every machine
- WS headline numbers use a V client; HTTP uses oha
- Not “we beat Axum” — peer remains ahead on this laptop

Raw dumps: `/tmp/viltrum-bench/`, `/tmp/viltrum-vs-axum/` (local).

## History

| Era | Headline HTTP (class of test) | WS note |
|-----|-------------------------------|---------|
| v0.3.x | ~27k GET c=100 | — |
| v0.4.0 | ~36k GET c=100; ~84k long c=50 | — |
| v0.5.0 | **~52k** GET c=100; **~85k** sustained 10s c=50 | Python client ~11k single / ~23k agg |
| v0.5.x | (HTTP unchanged in WS re-baseline) | **V client ~10k single / ~37k agg** |
| v0.7.0 PR1 lock | E ~85k / F ~71k vs Axum ~202k / ~192k | — |
| **v0.7.6 PR1–PR6** | **E ~98k / F ~91k** vs Axum ~191k / ~225k | WS table unchanged |
