# Viltrum

HTTP framework for [V](https://vlang.io). Small surface, own engine, single binary.

[![ci](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml/badge.svg)](https://github.com/Tuntii/viltrum/actions/workflows/ci.yml)

## Install

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh   # links ~/.vmodules/viltrum
v run examples/hello
```

Requires [V](https://github.com/vlang/v) on PATH.

## Features (v0.3.2)

- Own TCP + HTTP/1.1 engine (keep-alive, idle timeout, graceful shutdown)
- Router: `:param`, trailing `*wildcard`, slash normalize
- `app.mount` groups + `Mount.use` middleware
- `viltrum.chain` for route-level middleware
- `cors`, `static_files`, `logger`, `recover`
- `req.json_string` / `json_int` / `json_bool` (minimal body helpers)
- Zero deps beyond V stdlib

**Bench (honest, local laptop, oha):** ~**27k req/s** plaintext `GET /`. See [benches/RESULTS.md](benches/RESULTS.md).

## Example

```v
module main
import viltrum

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.use(viltrum.cors('*'))
	app.mount('/api', fn (mut m viltrum.Mount) {
		m.get('/hi/:name', fn (req viltrum.Request) viltrum.Response {
			name := req.param('name') or { 'world' }
			return viltrum.json(200, '{"hi":"${name}"}')
		})
		m.get('/files/*path', fn (req viltrum.Request) viltrum.Response {
			return viltrum.text(200, req.param('path') or { '' })
		})
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

## Examples

| Path | Port |
|------|------|
| `examples/hello` | 8080 |
| `examples/rest` | 8081 |
| `examples/features` | 8082 |

```bash
v test http/
v test router/
bash benches/run.sh
```

## Status

**v0.3.2** for tools and experiments. Not a TLS terminator (use a reverse proxy).

## License

MIT
