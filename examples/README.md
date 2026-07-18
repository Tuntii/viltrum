# Examples

Link the module first (from repo root):

```bash
mkdir -p ~/.vmodules
ln -sfn "$(pwd)" ~/.vmodules/viltrum
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

## Options sketch

```v
mut app := viltrum.new()
app.options(viltrum.ServerOptions{
    max_body_bytes: 256 * 1024
    require_host:   true
})
```
