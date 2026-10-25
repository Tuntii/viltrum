# Examples

Link the module first (from the repo root): `bash scripts/install.sh`.

| Example | Port | Shows |
|---------|------|-------|
| `hello` | 8080 | text responses, a `:param` |
| `rest` | 8081 | JSON in and out, shared state behind a mutex (handlers run on every worker thread) |
| `features` | 8082 | global middleware (logger, cors), groups, decoded query params, gzip, `worker_id`, static files (`/static/`), a form with a file upload (`/upload`) |
| `https` | 8080, 8443 | cleartext and HTTPS listeners on the same workers (`bash scripts/dev-cert.sh` first) |
| `ws_chat` | 8084 | WebSocket rooms: `:param` and query in `on_open`, state in `s.data`, `subscribe` / `publish` across workers, publishing from another thread |
| `sse` | 8085 | Server-Sent Events: a clock from a timer on each stream, a chat topic published from a handler, a CSV body generated as the client takes it (`on_drain`) |

```bash
v run examples/features
curl -s 'http://127.0.0.1:8082/search?q=caf%C3%A9'
curl -s --compressed -H 'Accept-Encoding: gzip' http://127.0.0.1:8082/big | head -c 40
```

```bash
bash scripts/dev-cert.sh && v run examples/https
curl -k https://127.0.0.1:8443/
```

```bash
v run examples/ws_chat
websocat 'ws://127.0.0.1:8084/chat/lobby?name=ada'   # and a second one as someone else
```

```bash
v run examples/sse                      # then open http://127.0.0.1:8085/ in two tabs
curl -N http://127.0.0.1:8085/events
curl -s http://127.0.0.1:8085/export.csv | tail -1
```

The HTTP client is not on the 1.x core yet; see the README.
