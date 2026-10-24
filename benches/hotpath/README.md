# Hot-path microbench

The request path without sockets: one worker, 16 pipelined requests per batch, 1M requests per run, best of 7.
Frame, parse, route, handler, response head and body, `Date` included. It leaves out the syscalls that
dominate a loaded server on most machines, so it shows what a change to the framework itself costs.

Use it as an A/B gate before merging anything that touches `Ctx`, the router or the writers: build the same
file against both trees and alternate the runs on one pinned CPU.

```bash
VMODULES=/path/to/base v -prod -o hot-base ./benches/hotpath   # a tree with viltrum/ at the old commit
VMODULES=/path/to/new  v -prod -o hot-new  ./benches/hotpath
for i in 1 2 3 4 5; do taskset -c 2 ./hot-base; taskset -c 2 ./hot-new; done
```

Compare the best and the median per route. On a noisy VM, a few percent either way is noise.

## 2026-10-23: request helpers (`html`, `redirect`, cookies, `Allow` on 405)

hostlab (8-vCPU VMware VM, Xeon E5-2690 v2), V 0.5.2 `-prod`, five alternated runs per build, ns per request:

| Route | v1.5.0 best | helpers best | v1.5.0 median | helpers median |
|-------|------------:|-------------:|--------------:|---------------:|
| `/` (text) | 403.8 | 382.5 | 411 | 389 |
| `/json` | 443.2 | 403.9 | 458 | 434 |
| `/users/:id` | 468.4 | 429.9 | 514 | 465 |

No route got slower. The helpers add nothing to `Ctx.begin`, so the gap is layout and noise, not a speedup.
