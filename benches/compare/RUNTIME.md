# Next runtime / I/O experiment (plan only)

Issue [#47](https://github.com/Tuntii/viltrum/issues/47). Not an implementation PR.

Laptop bar (see [RESULTS.md](../RESULTS.md)): own-stack keep-alive sits ~2× behind Axum. HTTP clone work is done. Remaining gap is V spawn-per-conn + std `net` vs Tokio.

Already shipped and measured:

| Spike | Keep-alive E/F | Product |
|-------|----------------|---------|
| SO_REUSEPORT multi-listener | no reliable keep-alive win | opt-in, default 1 |
| `conn_workers` pool | experimental | default 0 (spawn) |
| Linux epoll reactor | **~25% regress** vs spawn | default **off** |

## One next experiment

**Do not write a third reactor.** The one next measurement is:

> Multi-thread the existing spawn-per-conn path under V’s scheduler: same HTTP code, `v -prod` vs Axum shapes **E** and **F** in `run_vs_axum.sh`, with `GOMAX`-style thread count if V exposes it, else process-level `accept_workers=N` already in tree.

Not: io_uring, picoev, a second epoll rewrite, HTTP/2.

## A/B

1. Baseline: current default, `bash benches/compare/run_vs_axum.sh` E and F, 3 runs, medians in a table next to this file.
2. Variant: one scheduler/thread knob only (document the exact flag).
3. Same machine, same `oha` args as RESULTS.

## Merge default-on vs opt-in vs delete

| Result vs spawn baseline | Action |
|--------------------------|--------|
| ≥15% keep-alive E **and** upgrade/WS still work | consider default-on after a soak |
| 0–15% or win only on dial-storm | keep opt-in |
| regress or breaks WS/upgrade | do not merge; delete the spike if it is a new path |

Epoll already failed the default-on bar (regress + no upgrade/WS). Do not revive it as the next experiment.

## Upgrade / WS

Any I/O model that cannot run `app.upgrade` / `app.ws` on `engine.Conn` stays **opt-in experimental**, never default. The epoll path currently skips those routes.

## Non-goals

- Porting Tokio or another runtime into Viltrum
- HTTP/2 or HTTP/3
- Changing the public `new` → routes → `listen` / `ws` story
- Shipping a new default I/O model in 0.9.x without the numbers above

Implementation is a **follow-up issue**, only if this plan is accepted and the A/B is green.