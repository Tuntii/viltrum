# Examples

Link the module first (from the repo root): `bash scripts/install.sh`.

| Example | Port | Shows |
|---------|------|-------|
| `hello` | 8080 | text responses, a `:param` |
| `rest` | 8081 | JSON in and out, shared state behind a mutex (handlers run on every worker thread) |
| `features` | 8082 | global middleware (logger, cors), groups, decoded query params, gzip, `worker_id` |
| `https` | 8080, 8443 | cleartext and HTTPS listeners on the same workers (`bash scripts/dev-cert.sh` first) |
| `ws_echo` | 8084 | WebSocket: a `:param` read in `on_open`, per-connection state in `s.data`, `on_close` |

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
v run examples/ws_echo
websocat ws://127.0.0.1:8084/ws/lobby
```

Static files, uploads and the HTTP client are not on the 1.x core yet; see the README.
