# Bench notes (honest)

Machine: local CachyOS Linux (developer laptop), not a dedicated lab.
Date: 2026-07-18
Binary: tiny `GET /` -> `ok` (2 bytes), `recover` on, logging off, `handle_signals: false`
Tool: [oha](https://github.com/hatoo/oha) 1.15.0

```bash
oha -n 10000 -c 100 --no-tui http://127.0.0.1:18099/
```

## Result

| Metric | Value |
|--------|------:|
| Success rate | 100% |
| Requests | 10000 |
| Concurrency | 100 |
| **Requests/sec** | **~26706** |
| Average latency | 3.61 ms |
| p50 | 2.10 ms |
| p90 | 7.51 ms |
| p99 | 18.65 ms |
| Fastest | 0.07 ms |
| Slowest | 133.85 ms |
| Size/request | 2 B |

## What this is not

- Not a TechEmpower claim
- Not compared head-to-head with nginx / hyper / veb on the same night
- Not TLS, not HTTP/2, not large JSON bodies
- Tail latency has outliers (GC, scheduling, laptop noise)

## Reproduce

```bash
# needs oha on PATH
bash benches/run.sh
```

`benches/run.sh` starts a minimal server and prefers `oha`; falls back to sequential curl if missing.
