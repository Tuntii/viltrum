# Documentation

Viltrum 1.x is a small HTTP framework (HTTP/1.1, HTTP/2, WebSocket) for [V](https://vlang.io) on a zero-allocation core: one
`SO_REUSEPORT` epoll worker per CPU, a compile-time JSON encoder, Linux only. HTTPS runs in-process on the same
workers, or TLS terminates at a reverse proxy (Caddy, nginx).

Questions the docs do not answer: ask on [Discord](https://discord.gg/mY7JBbGhp).

## Start here

| Doc | When to read |
|-----|----------------|
| [getting-started.md](./getting-started.md) | Install, first server |
| [request-response.md](./request-response.md) | `Ctx` request and response calls, middleware |
| [connection.md](./connection.md) | Workers, buffers, limits, timeouts |
| [files.md](./files.md) | Static files: directories, `c.file`, caching validators, ranges |
| [forms.md](./forms.md) | Urlencoded forms, multipart uploads, upload limits |
| [tls.md](./tls.md) | HTTPS listeners, certificate reload, TLS policy |
| [http2.md](./http2.md) | HTTP/2 cleartext (h2c) beside HTTP/1.1, what handlers see, limits |
| [ws.md](./ws.md) | WebSocket routes, callbacks, closing, limits |
| [streaming.md](./streaming.md) | Streaming responses and Server-Sent Events: timers, sends from any thread, generated bodies |
| [client.md](./client.md) | Calling other HTTP services from a handler (`c.fetch`): upstreams, pooling, errors, timeouts |
| [deploy.md](./deploy.md) | Caddy/nginx, Host, timeouts, supervisor |
| [releasing.md](./releasing.md) | Semantic-release and commit conventions |

Also: [../CHANGELOG.md](../CHANGELOG.md), [../benches/RESULTS.md](../benches/RESULTS.md), examples in
[../examples/README.md](../examples/README.md) (`hello`, `rest`, `features`, `https`, `ws_chat`, `sse`).

## Not on the 1.x core yet

Generic upgrade and hijack, `https://` upstreams for the HTTP client, non-Linux platforms.
