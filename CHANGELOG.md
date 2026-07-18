# Changelog

## 0.3.1 — 2026-07-18

- Route groups via `app.mount('/api', fn (mut m Mount) { ... })`
- `viltrum.cors(origin)` middleware (OPTIONS preflight)
- `viltrum.static_files(prefix, root)` middleware + path traversal guard
- Parse fuzz / edge-case tests expanded
- Honest bench notes (`benches/RESULTS.md`, oha ~27k req/s plaintext GET)
- `ServerOptions.handle_signals` (disable in embedded/bench)

## 0.3.0 — 2026-07-18

- Graceful shutdown on SIGINT / SIGTERM (listener close)
- Keep-alive idle timeout (`ServerOptions.idle_timeout`)
- `viltrum.recover` middleware (response hardening)
- Logger prints duration ms
- `benches/run.sh` throughput smoke

## 0.2.1 — 2026-07-18

- `App.options(ServerOptions)`
- Query decode, trailing slash normalize, header combine
- Response `.header()`, Host check, write_all, CI

## 0.2.0 — 2026-07-18

- Multi-read framing, keep-alive, params, rest example

## 0.1.0 — 2026-07-18

- Initial engine PoC
