# Bench notes (honest)

| | |
|--|--|
| **Version** | Viltrum **v0.4.0** (`-prod` binary) |
| **Date** | 2026-07-19 |
| **Machine** | local CachyOS Linux (developer laptop), not a dedicated lab |
| **CPU** | AMD Ryzen 7 4800H (16 threads), ~14 GiB RAM |
| **Tool** | [oha](https://github.com/hatoo/oha) **1.15.0** |

Handler profile: `recover` on, **logging off**, `handle_signals: false`, cleartext HTTP/1.1 keep-alive.

Reproduce:

```bash
bash benches/run.sh
```

---

## A) Plaintext GET / — `n=10000` `c=100`

`GET /` → `ok` (2 B)

```text
Success rate:  100%
Requests/sec:  ~36210
Average:       2.65 ms
p50 / p99:     1.55 ms / 9.52 ms
```

## B) Higher concurrency GET / — `n=10000` `c=500`

Same handler.

```text
Success rate:  100%
Requests/sec:  ~7912
Average:       34.9 ms
p50 / p99:     3.4 ms / ~1.24 s
```

Note: dial/connect spikes dominate at high `c` on a laptop. Still 100% 200 — not a correctness failure.

## C) POST JSON body — `n=5000` `c=100`

`POST /echo` with `{"title":"bench"}` → small JSON via `json_string`.

```text
Success rate:  100%
Requests/sec:  ~55154
Average:       1.58 ms
p50 / p99:     0.98 ms / 15.8 ms
```

Run after A/B (warm process / CPU). Treat as same-session smoke, not isolated peak.

## D) Longer GET / — `n=50000` `c=50`

```text
Success rate:  100%
Requests/sec:  ~83752
Average:       0.59 ms
p50 / p99:     0.46 ms / 3.03 ms
```

Lower concurrency + longer run often looks better than A on this stack (less dial storm, warmer caches).

---

## Summary table

| Scenario | n | c | req/s (approx) | Success |
|----------|--:|--:|---------------:|--------:|
| A GET / | 10k | 100 | **~36k** | 100% |
| B GET / | 10k | 500 | **~7.9k** | 100% |
| C POST JSON | 5k | 100 | **~55k** | 100% |
| D GET / long | 50k | 50 | **~84k** | 100% |

Headline comparable to previous README “~27k” claim: **scenario A ~36k** on this run (v0.4.0 `-prod`, same class of test). Numbers move with load and thermals.

---

## What this is not

- Not TechEmpower
- Not TLS / HTTP/2 / large payloads / multi-node
- Not a guarantee of multi-hundred-k RPS on every machine
- Raw oha dumps from last run: `/tmp/viltrum-bench/` (local)

## Previous note (v0.3.x era, 2026-07-18)

Same laptop class, oha, GET `/` c=100: **~27k req/s**. Kept for history only; re-run `benches/run.sh` after engine changes.
