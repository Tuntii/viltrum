# Multi-core epoll vs spawn (after the read-path change)

| | |
|--|--|
| **Date** | 2026-09-25 |
| **V** | 0.5.2 `1188128` |
| **Machine** | CachyOS Linux, Ryzen 7 4800H (16 thr) |
| **Tool** | oha 1.15.0, Viltrum `-prod` |
| **Flag** | `ServerOptions.epoll_cores` (0 = spawn, 16 = one loop per core) |
| **Reproduce** | `bash benches/compare/run_hotpath_exp.sh` |

Same HTTP parse and serialize on both paths. The spawn path in this run already installs `SO_RCVTIMEO` once and then `recv` (no per-read `select`).

## Results (3-run median, 100% success)

| mode | E (10s, c=50) | F (10s, c=100) | vs spawn E |
|------|-------------:|---------------:|-----------:|
| spawn + `recover` | **243532** | **207436** | baseline |
| spawn, no middleware | **226385** | **208933** | |
| `epoll_cores=16` + `recover` | **244358** | **261497** | **+0.3%** |
| `epoll_cores=16`, no middleware | **245334** | **264815** | **+8.4%** vs bare spawn |

Raw:

| mode | E runs | F runs |
|------|--------|--------|
| spawn + recover | 225030, 243532, 245587 | 214434, 207425, 207436 |
| spawn bare | 226385, 225111, 248343 | 221529, 207581, 208933 |
| cores + recover | 250658, 244358, 238544 | 264446, 261497, 244147 |
| cores bare | 248172, 228340, 245334 | 264815, 265078, 263258 |

## Decision

Keep-alive **E** with `recover` is the gate (the published bench shape). **+0.3%** is under the **+15%** bar. Bare E is **+8.4%**, also under the bar. F is higher on the epoll path. That is not the gate.

**Default I/O model stays spawn-per-conn** (`epoll_cores` 0, `use_epoll` false). `epoll_cores` stays opt-in. Upgrade and WebSocket stay on the spawn path, which is the default. The epoll path can hand a matched upgrade off to its own thread. That was not enough to change the default.

```v
app.server_options(viltrum.ServerOptions{
	epoll_cores: 16 // opt-in; keep-alive E did not clear +15%
})
```
