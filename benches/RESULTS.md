# Bench notes (honest)

Machine: local CachyOS Linux (developer laptop), not a dedicated lab.
Date: 2026-07-18
Tool: [oha](https://github.com/hatoo/oha) 1.15.0

## A) Plaintext GET /

Binary: `GET /` -> `ok` (2 B), recover on, logging off, `handle_signals: false`

```bash
oha -n 10000 -c 100 --no-tui http://127.0.0.1:PORT/
```

| Metric | Value |
|--------|------:|
| Success | 100% |
| **req/s** | **~26706** |
| Average | 3.61 ms |
| p50 / p99 | 2.10 / 18.65 ms |

## B) Higher concurrency GET / (`-c 500`)

Same handler.

```bash
oha -n 10000 -c 500 --no-tui http://127.0.0.1:PORT/
```

| Metric | Value |
|--------|------:|
| Success | 100% |
| **req/s** | **~7940** |
| Average | 36 ms |
| p50 / p99 | 6.8 ms / ~1.0 s |

Note: laptop + many connections; dialup/tail spikes dominate. Not a failure of correctness (still 100% 200).

## C) POST JSON body

Handler: `json_string("title")` -> small JSON response (17 B).

```bash
oha -n 5000 -c 100 -m POST \
  -H 'Content-Type: application/json' \
  -d '{"title":"bench"}' \
  --no-tui http://127.0.0.1:PORT/echo
```

| Metric | Value |
|--------|------:|
| Success | 100% |
| **req/s** | **~24663** |
| Average | 3.82 ms |
| p50 / p99 | 2.22 / 20.7 ms |

## What this is not

- Not TechEmpower
- Not TLS / HTTP/2 / large payloads
- Numbers move with CPU load, thermal, and scheduler noise

## Reproduce

```bash
bash benches/run.sh          # baseline GET
# or install oha: https://github.com/hatoo/oha/releases
```
