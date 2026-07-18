# Viltrum

HTTP framework for [V](https://vlang.io). Small surface, own engine, single binary.

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)

```
request -> multi-read frame -> parse -> route -> middleware -> response
           (keep-alive, idle timeout, graceful shutdown)
```

## Features (v0.3)

- Own TCP accept loop and HTTP/1.1 framing (not a wrapper around another stack)
- Keep-alive + idle timeout between requests
- Graceful shutdown on SIGINT / SIGTERM
- Router with `:param`, trailing slash normalize, query decode
- Middleware: `logger`, `recover`
- `App.options(ServerOptions{...})` for limits and timeouts
- `text` / `json` / `empty` helpers, `resp.header(...)`
- Zero external deps beyond V stdlib

## Quick start

```bash
git clone https://github.com/Tuntii/viltrum.git
cd viltrum
mkdir -p ~/.vmodules && ln -sfn "$(pwd)" ~/.vmodules/viltrum
v run examples/hello
```

```v
module main

import viltrum

fn hello(req viltrum.Request) viltrum.Response {
	name := req.param('name') or { 'world' }
	return viltrum.json(200, '{"message":"hello, ${name}"}')
}

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.use(viltrum.logger)
	app.get('/hi/:name', hello)
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

Ctrl+C stops the listener cleanly.

## Examples

See [examples/README.md](examples/README.md).

```bash
v run examples/hello   # :8080
v run examples/rest    # :8081
bash benches/run.sh    # rough throughput smoke
```

## Layout

| Path | Role |
|------|------|
| `engine/` | TCP, framing, shutdown, idle timeout |
| `http/` | Request / Response, parse |
| `router/` | Routes and params |
| `viltrum.v` | App facade |
| `examples/` | hello, rest |
| `benches/` | throughput script |

## Tests

```bash
v test http/
```

## Status

**v0.3.0** usable for experiments and small tools. Not a claim of production hardening.

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT
