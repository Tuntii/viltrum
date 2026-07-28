# Epic: HTTP/1.1 hot path → Axum-competitive cleartext

**Status:** active  
**Tracks:** epic [#16](https://github.com/Tuntii/viltrum/issues/16) · children [#17](https://github.com/Tuntii/viltrum/issues/17)–[#23](https://github.com/Tuntii/viltrum/issues/23) · [ROADMAP.md](../../ROADMAP.md) v0.8  
**Branch prefix:** `perf/http11-*`  
**Date:** 2026-07-29

Own-stack cleartext HTTP/1.1 should sit in the **same league** as a minimal Rust Axum app on the same laptop and client. Not a promise to beat Tokio forever; not a wrapper around Hyper.

---

## 1. Goal

| Bar | Meaning (same machine, oha, cleartext) |
|-----|----------------------------------------|
| **League** (primary) | Sustained `GET /` **≥ ~150k req/s** at 10s c=50, or **≥ ~0.75×** concurrent Axum on that run |
| **Parity** (stretch) | Within **±15%** of Axum on scenarios E/F from `benches/compare/` |
| **Correctness** | Existing suites green; 100% success on compare scenarios; no public API break unless versioned |

Reference peer: Axum 0.8 + tokio multi-thread release+LTO (`benches/compare/axum`).

### Non-goals

- Wrapping Hyper / Axum / other stacks
- HTTP/2, HTTP/3
- TLS hot path (separate; cleartext first)
- Fake benches (static wire-only handlers that skip parse)
- Guaranteeing multi-hundred-k RPS as a product SLA

---

## 2. Baseline (PR1 lock)

Locked on developer laptop (CachyOS, Ryzen 7 4800H, 16 thr), **2026-07-29**, Viltrum **v0.7.0**, oha **1.15.0**, both sides 100% success.

| Scenario | Viltrum | Axum | Axum / Viltrum |
|----------|--------:|-----:|---------------:|
| A GET n=10k c=100 | ~61k | ~162k | ~2.6× |
| D GET n=50k c=50 | ~82k | ~200k | ~2.4× |
| **E GET 10s c=50** | **~85k** | **~202k** | **~2.4×** |
| F GET 10s c=100 | ~71k | ~192k | ~2.7× |
| C POST echo n=5k c=100 | ~54k | ~153k | ~2.8× |

Reproduce:

```bash
bash benches/compare/run_vs_axum.sh
# summary: /tmp/viltrum-vs-axum/summary.txt
```

**Headline metrics for PR gates:** scenario **E** and **F** (sustained). Update this table when a PR claims a material win (plan bar: roughly **>10%** sustained on E, or clear reduction of a named alloc on the profile).

---

## 3. Workstream (PR sequence)

| PR | Title | Intent | Exit |
|----|--------|--------|------|
| **PR1** [#17](https://github.com/Tuntii/viltrum/issues/17) | Instrument + baseline lock | Compare harness in-tree; baseline numbers; how to re-run; profile pointer | This doc §2 + `benches/compare/` ship |
| **PR2** [#18](https://github.com/Tuntii/viltrum/issues/18) | Byte-level `parse_request` | No full `raw.bytestr()` for headers; request-line + fields as byte walk | Parse tests green; E improves or alloc proof |
| **PR3** [#19](https://github.com/Tuntii/viltrum/issues/19) | Single message ownership | Kill double body materialization (`finish_message` + parse body clone) | One body ownership path; tests green |
| **PR4** [#20](https://github.com/Tuntii/viltrum/issues/20) | Response `[]u8` builder + casing cache | Replace string `+=` / per-header canonicalize on hot path | Serialize cheaper; E/F measure |
| **PR5** [#21](https://github.com/Tuntii/viltrum/issues/21) | Conn-local buffer reuse | Assembly + write scratch reused for keep-alive | Fewer allocs per request on hot path |
| **PR6** [#22](https://github.com/Tuntii/viltrum/issues/22) | Multi-accept / `SO_REUSEPORT` experiment | Measure only; may not land default | Numbers in compare note; default off unless clear win |
| **PR7** [#23](https://github.com/Tuntii/viltrum/issues/23) | Document remaining gap | Honest RESULTS / this doc after P1–P6 | Final table + what V/runtime still costs |

Do **not** skip PR1: without a locked baseline, later PRs cannot claim wins.

Implementation detail for PRs 2–5 is guided by [benches/HTTP_PROFILE.md](../../benches/HTTP_PROFILE.md) (double-work summary).

---

## 4. PR rules

1. One theme per PR; keep reviewable.
2. `v test http/ router/ engine/ ws/` green.
3. If claiming perf: re-run `bash benches/compare/run_vs_axum.sh` and paste E/F (and summary) in the PR body.
4. No public API break without a deliberate version decision.
5. Prefer correctness over chasing a single oha sample (variance is real on a laptop).

---

## 5. Success (close epic)

- [ ] League bar met **or** documented “best effort” with remaining gap vs Tokio explained
- [ ] Baseline table updated end-to-end
- [ ] `HTTP_PROFILE.md` Decision section refreshed
- [ ] ROADMAP checkbox for this epic closed

---

## 6. Decisions log

| Decision | Choice |
|----------|--------|
| Peer | Axum cleartext, not Hyper alone / not wrk-only |
| Primary gate scenarios | E (10s c=50), F (10s c=100) |
| Order | Alloc/parse first (PR2–5), runtime experiment last (PR6) |
| Wrapper stacks | Out of scope forever for this epic |
