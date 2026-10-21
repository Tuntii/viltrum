# Documentation

Viltrum 1.x is a small HTTP/1.1 framework for [V](https://vlang.io) on a zero-allocation core: one
`SO_REUSEPORT` epoll worker per CPU, a compile-time JSON encoder, Linux only. HTTPS runs in-process on the same
workers, or TLS terminates at a reverse proxy (Caddy, nginx).

## Start here

| Doc | When to read |
|-----|----------------|
| [getting-started.md](./getting-started.md) | Install, first server |
| [request-response.md](./request-response.md) | `Ctx` request and response calls, middleware |
| [connection.md](./connection.md) | Workers, buffers, limits, timeouts |
| [tls.md](./tls.md) | HTTPS listeners, certificate reload, TLS policy |
| [ws.md](./ws.md) | WebSocket routes, callbacks, closing, limits |
| [deploy.md](./deploy.md) | Caddy/nginx, Host, timeouts, supervisor |
| [releasing.md](./releasing.md) | Semantic-release and commit conventions |

Also: [../CHANGELOG.md](../CHANGELOG.md), [../benches/RESULTS.md](../benches/RESULTS.md), examples in
[../examples/README.md](../examples/README.md) (`hello`, `rest`, `features`, `https`, `ws_echo`).

## Not on the 1.x core yet

Generic upgrade and hijack, static files, forms and uploads, the HTTP client, non-Linux platforms. They
return on the new core.

## v0.13 reference (not 1.x)

[upgrade.md](./upgrade.md) describes the v0.13 upgrade API and is kept for reference only.
