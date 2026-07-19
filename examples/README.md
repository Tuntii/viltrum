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

## Server options sketch

```v
mut app := viltrum.new()
app.server_options(viltrum.ServerOptions{
    max_body_bytes: 256 * 1024
    max_conns:      1024
    send_date:      true
    server_header:  'viltrum'
    require_host:   true
})
```

Proxy deploy notes: [docs/deploy.md](../docs/deploy.md).
