# Examples

Docs index: [../docs/README.md](../docs/README.md). Link the module first (from repo root):

```bash
bash scripts/install.sh
# or:
mkdir -p ~/.vmodules && ln -sfn "$(pwd)" ~/.vmodules/viltrum
```

## hello — `:8080`

```bash
v run examples/hello
```

```bash
curl -s http://127.0.0.1:8080/
curl -s http://127.0.0.1:8080/health
curl -s http://127.0.0.1:8080/hi/tunay
# trailing slash OK
curl -s http://127.0.0.1:8080/hi/tunay/
```

## rest — `:8081` in-memory todos

```bash
v run examples/rest
```

```bash
curl -s http://127.0.0.1:8081/todos
curl -s -X POST http://127.0.0.1:8081/todos \
  -H 'Content-Type: application/json' \
  -d '{"title":"ship polish"}'
curl -s http://127.0.0.1:8081/todos/1
curl -s -X DELETE http://127.0.0.1:8081/todos/1 -w '\n%{http_code}\n'
```

## upgrade_echo — `:8083` connection hijack

```bash
v run examples/upgrade_echo
printf 'GET /echo HTTP/1.1\r\nHost: localhost\r\n\r\nhello\n' | nc 127.0.0.1 8083
```

See [docs/upgrade.md](../docs/upgrade.md).

## ws_echo — `:8084` first-party WebSocket

```bash
v run examples/ws_echo
websocat ws://127.0.0.1:8084/ws
```

See [docs/ws.md](../docs/ws.md).

## https_hello — `:8443` in-process TLS

```bash
bash scripts/dev-cert.sh
v run examples/https_hello
curl -k https://127.0.0.1:8443/
```

## wss_echo — `:8444` WebSocket over TLS

```bash
bash scripts/dev-cert.sh
v run examples/wss_echo
websocat -k wss://127.0.0.1:8444/ws
```

See [docs/tls.md](../docs/tls.md).

## upload — `:8085` urlencoded + multipart

```bash
v run examples/upload
curl -s -d 'title=urlencoded' http://127.0.0.1:8085/form
curl -s -F title=hi -F file=@README.md http://127.0.0.1:8085/upload
# JSON `filename` is FormPart.safe_filename() (path stripped; `..` → unnamed)
```

## Full-stack starter — separate repo

Teaching app: same-process JSON API + static SPA, bearer auth, users, items.

**Repo:** [Tuntii/full-stack-viltrum-template](https://github.com/Tuntii/full-stack-viltrum-template)

```bash
git clone https://github.com/Tuntii/full-stack-viltrum-template.git
cd full-stack-viltrum-template
bash scripts/setup.sh
v run .
# open http://127.0.0.1:8090/  ·  admin@example.com / changethis
```

Inspired by [fastapi/full-stack-fastapi-template](https://github.com/fastapi/full-stack-fastapi-template) — not a port.

## Server options sketch

```v
import time
import viltrum { new, ServerOptions, new_conn_stats }

mut stats := new_conn_stats()
mut app := new()
app.server_options(ServerOptions{
	max_body_bytes: 256 * 1024
	max_conns:      1024
	drain_timeout:  10 * time.second
	stats:          stats
	send_date:      true
	server_header:  'viltrum'
	require_host:   true
})
```

Proxy deploy notes: [docs/deploy.md](../docs/deploy.md).
