# Epoll reactor spike (Linux)

| | |
|--|--|
| **Date** | 2026-08-05 |
| **Flag** | `ServerOptions.use_epoll` (default **false**) |
| **Scope** | Cleartext only; no upgrade/WS on this path |

## Design

```text
default:  accept → spawn handle_conn (blocking I/O, many goroutines)
use_epoll: single thread + epoll + nonblocking recv/send
           state machine: assemble → parse_request → handler → write_buf
```

Own HTTP stack kept (`http.parse_request`, `to_bytes_for_method_into`). Not picoev/pico_http_parser.

## A/B (this laptop, 3 runs, oha)

| mode | E median (c=50) | F median (c=100) |
|------|----------------:|-----------------:|
| spawn (default) | ~88k | ~78k |
| **use_epoll** | **~67k** | **~60k** |

**Regression ~25%.** Not a path to 120k in this form.

## Why slower (honest)

1. **Single thread** does accept + parse + handler + write for all conns; no multi-core HTTP work.
2. Spike still clones message slices / assem leftovers; not as tuned as the blocking conn path (PR3–PR5 buffers).
3. oha keep-alive needs many concurrent sessions; one core saturates earlier.
4. Tokio wins with **many cores + nonblocking**, not nonblocking alone on one core.

## Decision

| | |
|--|--|
| Default | **false** (spawn-per-conn) |
| Productize as recommended? | **No** |
| Keep code? | **Yes** — opt-in experiment + platform for multi-reactor follow-up |
| Next if chasing 120k+ | N epoll threads + SO_REUSEPORT (one loop per core), or drop reactor and accept ~100k ceiling |

## Drain / ConnStats

The reactor does **not** share `wait_drain` or `ConnStats` with the spawn-per-conn path. `max_conns` is a local slot count only. Listen log: `epoll reactor; drain_timeout/ConnStats unused`. Default `use_epoll: false` is unchanged. See [RUNTIME.md](./RUNTIME.md) before any new I/O spike.

## Opt-in

```v
app.server_options(viltrum.ServerOptions{
	use_epoll: true // Linux only
})
```
