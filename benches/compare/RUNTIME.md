# Runtime / I/O experiment

Issue [#47](https://github.com/Tuntii/viltrum/issues/47) was the plan. Measured 2026-09-25: [SCHEDULER.md](./SCHEDULER.md). Default unchanged.

Laptop bar (see [RESULTS.md](../RESULTS.md)): own-stack keep-alive sits ~2× behind Axum. HTTP clone work is done. Remaining gap is V spawn-per-conn + std `net` vs Tokio.

Already shipped and measured:

| Spike | Keep-alive E/F | Product |
|-------|----------------|---------|
| SO_REUSEPORT multi-listener | no reliable keep-alive win | opt-in, default 1 |
| `conn_workers` pool | experimental | default 0 (spawn) |
| Linux epoll reactor | **~25% regress** vs spawn | default **off** |
| `spawn` thread cap | none (`pthread` per conn). `accept_workers=8`: E **−0.6%**, F **−3.4%** | default unchanged |

## The experiment (measured)

**Do not write a third reactor.** The one measurement was:

> Multi-thread the existing spawn-per-conn path under V’s scheduler: same HTTP code, `v -prod` vs Axum shapes **E** and **F**, with a `GOMAX`-style thread count if V exposes it, else process-level `accept_workers=N` already in tree.

Not: io_uring, picoev, a second epoll rewrite, HTTP/2.

**Result:** V 0.5.2 `spawn` is one pthread per connection. `VJOBS` does not size it. Fallback `accept_workers=8` vs `1`: E median **−0.6%**, F **−3.4%**, 100% success. Under the 15% bar. Details and raw runs: [SCHEDULER.md](./SCHEDULER.md). Reproduce with `bash benches/compare/run_sched_exp.sh`.

## A/B (done)

1. Baseline: `accept_workers=1`, shapes E and F, 3 runs. Median E **107.4k**, F **98.7k**.
2. Variant: one knob, `accept_workers=8`. Median E **106.7k**, F **95.4k**.
3. Same machine, same `oha` args as RESULTS. Axum same session: E **217.4k**, F **226.1k**.

Table: [SCHEDULER.md](./SCHEDULER.md).

## Merge default-on vs opt-in vs delete

| Result vs spawn baseline | Action |
|--------------------------|--------|
| ≥15% keep-alive E **and** upgrade/WS still work | consider default-on after a soak |
| 0–15% or win only on dial-storm | keep opt-in |
| regress or breaks WS/upgrade | do not merge; delete the spike if it is a new path |

Applied 2026-09-25: accept_workers=8 is the second row (flat / slight F regress). It is not a new path, so it stays opt-in. Epoll already failed the default-on bar (regress + no upgrade/WS). Do not revive it.

## Upgrade / WS

Any I/O model that cannot run `app.upgrade` / `app.ws` on `engine.Conn` stays **opt-in experimental**, never default. The epoll path currently skips those routes.

## Non-goals

- Porting Tokio or another runtime into Viltrum
- HTTP/2 or HTTP/3
- Changing the public `new` → routes → `listen` / `ws` story
- Shipping a new default I/O model without the numbers above

The A/B is recorded. It is not green. No follow-up reactor issue.