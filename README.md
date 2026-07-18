# Viltrum

HTTP framework for [V](https://vlang.io). Small surface, own engine, single binary.

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)

```
request -> frame -> parse -> route/mount -> middleware -> response
```

## Features (v0.3.1)

- Own TCP + HTTP/1.1 engine (keep-alive, idle timeout, optional graceful shutdown)
- Router + **`app.mount` groups**
- Middleware: `logger`, `recover`, **`cors`**, **`static_files`**
- `App.options(ServerOptions{...})`
- Path params, query decode, trailing slash normalize
- Zero deps beyond V stdlib

**Bench (honest, local laptop):** ~**27k req/s** plaintext `GET /` with oha `-n 10000 -c 100`. See [benches/RESULTS.md](benches/RESULTS.md).

## Quick start

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
mkdir -p ~/.vmodules && ln -sfn "$(pwd)" ~/.vmodules/viltrum
v run examples/hello
```

```v
module main
import viltrum

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.use(viltrum.cors('*'))
	app.use(viltrum.static_files('/static', './public'))
	app.mount('/api', fn (mut m viltrum.Mount) {
		m.get('/ping', fn (_ viltrum.Request) viltrum.Response {
			return viltrum.json(200, '{"pong":true}')
		})
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

## Examples

| Path | Port | What |
|------|------|------|
| `examples/hello` | 8080 | minimal |
| `examples/rest` | 8081 | in-memory todos |
| `examples/features` | 8082 | mount + cors + static |

```bash
v test http/
bash benches/run.sh   # needs oha
```

## Status

**v0.3.1** — useful for tools and experiments. Not a production TLS terminator.

## License

MIT
