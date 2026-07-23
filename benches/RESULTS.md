# Bench notes (honest)

| | |
|--|--|
| **Version** | Viltrum **v0.5.x** (`-prod` server binary) |
| **Date** | 2026-07-23 (WS client re-baseline); HTTP table from 2026-07-19 |
| **Machine** | local CachyOS Linux (developer laptop), not a dedicated lab |
| **CPU** | AMD Ryzen 7 4800H (16 threads), ~14 GiB RAM |
| **Tools** | [oha](https://github.com/hatoo/oha) **1.15.0** (HTTP); **V first-party** masked WS load client (`benches/ws_load_client.v`) |

Handler profile: `recover` on (HTTP), **logging off**, `handle_signals: false`, cleartext only.

Reproduce:

```bash
bash benches/run.sh      # HTTP
bash benches/run_ws.sh   # WebSocket echo (headline = V client)
CLIENT=python bash benches/run_ws.sh   # optional Python smoke
bash benches/soak_ws.sh  # WS multi-conn echo + close-storm (correctness)
# SOAK_SECONDS=120 bash benches/soak_ws.sh   # optional longer local soak
```

---

## HTTP engine

### Fixed-n (oha)

| Scenario | n | c | req/s | Success | Notes |
|----------|--:|--:|------:|--------:|-------|
| A GET `/` | 10k | 100 | **~52k** | 100% | short burst |
| B GET `/` | 10k | 500 | **~7.8k** | 100% | dial storm; p99 large |
| C POST `/echo` JSON | 5k | 100 | **~63k** | 100% | warm process |
| D GET `/` longer | 50k | 50 | **~95k** | 100% | best fixed-n on this run |

### Sustained duration (oha `-z`)

| Scenario | duration | c | req/s | Success |
|----------|----------|--:|------:|--------:|
| E GET `/` | 10s | 50 | **~85k** | 100% |
| F GET `/` | 10s | 100 | **~64k** | 100% |
| G GET `/` | 5s | 200 | **~59k** | 100% |

**Headline (honest):** on this laptop, cleartext `GET /` sustains **~60–85k req/s** depending on concurrency; short low-`c` bursts can touch **~95k**. Not a lab guarantee.

Snippet from E (10s, c=50):

```text
Success rate:  100%
Requests/sec:  ~85150
Average:       0.58 ms
p50 / p99:     0.43 ms / 2.12 ms
```

---

## WebSocket (`ws://` echo)

Server: `app.ws` echo text/binary. **Headline client: V** (`benches/ws_load_client.v`), masked frames, multi-conn via spawn.

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

Raw dumps: `/tmp/viltrum-bench/` (local).

## History

| Era | Headline HTTP (class of test) | WS note |
|-----|-------------------------------|---------|
| v0.3.x | ~27k GET c=100 | — |
| v0.4.0 | ~36k GET c=100; ~84k long c=50 | — |
| v0.5.0 | **~52k** GET c=100; **~85k** sustained 10s c=50 | Python client ~11k single / ~23k agg |
| **v0.5.x** | (HTTP unchanged in this re-baseline) | **V client ~10k single / ~37k agg** |
