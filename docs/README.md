# Documentation

Viltrum is a small HTTP framework for [V](https://vlang.io) with its **own** TCP accept loop and HTTP/1.1 framing. Cleartext first; reverse-proxy TLS is first-class; in-process TLS is planned.

## Start here

| Doc | When to read |
|-----|----------------|
| [getting-started.md](./getting-started.md) | Install, first server, module layout |
| [request-response.md](./request-response.md) | `Request` / `Response`, `ctx`, middleware |
| [connection.md](./connection.md) | Accept → read → handler → keep-alive / close |
| [upgrade.md](./upgrade.md) | `app.upgrade`, `Conn`, leftover ownership |
| [ws.md](./ws.md) | First-party WebSocket (`ws://`) |
| [deploy.md](./deploy.md) | Caddy/nginx, Host, timeouts, WS hop-by-hop |
| [releasing.md](./releasing.md) | Semantic-release and commit conventions |

## Product plan

| Doc | Topic |
|-----|--------|
| [../ROADMAP.md](../ROADMAP.md) | Phases 0.3 → 0.7+ |
| [../CHANGELOG.md](../CHANGELOG.md) | Shipped releases |
| [../benches/RESULTS.md](../benches/RESULTS.md) | Honest laptop numbers |

## Examples

| Path | Port | Focus |
|------|------|--------|
| `examples/hello` | 8080 | Minimal app |
| `examples/rest` | 8081 | JSON CRUD-ish |
| `examples/features` | 8082 | Mount, chain, static, wildcards |
| `examples/upgrade_echo` | 8083 | Raw hijack |
| `examples/ws_echo` | 8084 | WebSocket echo |

See [examples/README.md](../examples/README.md).

## Mental model

```text
TCP accept
  → HTTP/1.1 parse (Content-Length bodies only)
  → route match
       ├─ normal Handler → Response → keep-alive / close
       └─ upgrade / app.ws → Conn (or WsSocket) owns the stream
```

One public app surface (`viltrum.App`). Engine modules (`engine`, `http`, `router`, `ws`) stay importable for advanced use.
