# Bench notes (honest)

| | |
|--|--|
| **Version** | Viltrum **v0.5.0** (`-prod` binary) |
| **Date** | 2026-07-19 |
| **Machine** | local CachyOS Linux (developer laptop), not a dedicated lab |
| **CPU** | AMD Ryzen 7 4800H (16 threads), ~14 GiB RAM |
| **Tools** | [oha](https://github.com/hatoo/oha) **1.15.0** (HTTP); Python 3 raw RFC 6455 client (WS) |

Handler profile: `recover` on (HTTP), **logging off**, `handle_signals: false`, cleartext only.

Reproduce:

```bash
bash benches/run.sh      # HTTP
bash benches/run_ws.sh   # WebSocket echo (throughput, Python client)
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

Server: `app.ws` echo text/binary. Client: Python threads, masked frames, TCP_NODELAY.

| Scenario | Shape | Result | Success |
|----------|-------|--------|--------:|
| A single conn | 20k × 64 B text echo | **~11.3k msg/s** | 100% |
| B concurrent | 32 conn × 5k × 64 B | **~23.0k msg/s** aggregate | 100% |
| C concurrent | 100 conn × 1k × 64 B | **~18.7k msg/s** aggregate | 100% |
| D single large | 5k × 1 KiB text echo | **~5.2k msg/s** (~10.7 MiB/s rx+tx) | 100% |

Correctness smoke (same binary): handshake 101 + Accept, text/binary echo, auto-pong, unmasked client → close **1002**.

**Headline (honest):** multi-conn echo sits in the **~15–25k msg/s** band on this laptop for small payloads; single-conn ~**11k msg/s**. Client is Python (not a C loadgen), so these are **lower bounds** on server capacity, not a pure server-only ceiling.

### WS write-path notes (0.5.x)

- Server frames encode into a **reused per-socket scratch buffer** (`encode_server_into`); public write APIs unchanged.
- Close-storm correctness is covered by `bash benches/soak_ws.sh` (was previously racing: `Socket` copied `Conn` and double-closed fds).
- Throughput re-measure with `run_ws.sh` still uses a Python client; treat numbers as lower bounds until a first-party load client (#7).

---

## What this is not

- Not TechEmpower / not multi-node
- Not TLS / `wss://` / HTTP/2
- Not large-payload or slowloris stress
- Not a promise of multi-hundred-k RPS on every machine
- WS numbers include a Python client; HTTP uses oha (faster client)

Raw dumps: `/tmp/viltrum-bench/` (local).

## History

| Era | Headline HTTP (class of test) |
|-----|-------------------------------|
| v0.3.x | ~27k GET c=100 |
| v0.4.0 | ~36k GET c=100; ~84k long c=50 |
| **v0.5.0** | **~52k** GET c=100; **~85k** sustained 10s c=50; **~95k** n=50k c=50 |
