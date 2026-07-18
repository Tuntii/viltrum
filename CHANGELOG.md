# Changelog

## 0.3.2 — 2026-07-18

- Trailing wildcard routes: `/files/*path`
- JSON field helpers: `req.json_string` / `json_int` / `json_bool` (minimal)
- Route middleware: `viltrum.chain([...], handler)` and `Mount.use`
- `scripts/install.sh` for `~/.vmodules` link
- Heavier bench notes (JSON body + higher concurrency)
- features example: wildcard, chain, mount header, json echo

## 0.3.1 — 2026-07-18

- `app.mount`, cors, static_files, parse fuzz, honest oha bench, GitHub Release

## 0.3.0 — 2026-07-18

- Graceful shutdown, idle timeout, recover, timed logger

## 0.2.x — 2026-07-18

- Framing, keep-alive, polish

## 0.1.0 — 2026-07-18

- Initial PoC
