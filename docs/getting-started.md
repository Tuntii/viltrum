# Getting started

## Requirements

- [V](https://github.com/vlang/v) on `PATH` (`v version`)
- Linux/macOS (Windows untested)

## Install

```bash
git clone https://github.com/Tuntii/viltrum.git
cd viltrum
bash scripts/install.sh
```

`install.sh` symlinks the repo to `~/.vmodules/viltrum` so `import viltrum` resolves.

To point at another checkout later:

```bash
ln -sfn /path/to/viltrum ~/.vmodules/viltrum
```

## Import style

Docs and examples prefer a **selective import** (ergonomic handlers):

```v
import viltrum {
	new
	recover
	text
	json
	Request
	Response
	// add: Conn, WsSocket, WsOptions, ServerOptions, chain, cors, Mount, …
}
```

Then write `new()`, `Request`, `text(...)` without a module prefix.

Fully qualified still works:

```v
import viltrum

mut app := viltrum.new()
// viltrum.Request, viltrum.text, …
```

Short alias is fine in larger apps: `import viltrum as v`.

## Hello

```bash
v run examples/hello
# curl http://127.0.0.1:8080/
```

Minimal program:

```v
module main

import viltrum {
	new
	text
	Request
	Response
}

fn main() {
	mut app := new()
	app.get('/', fn (req Request) Response {
		return text(200, 'hello\n')
	})
	app.listen('127.0.0.1:8080') or { panic(err) }
}
```

## Layout (this repo)

| Path | Role |
|------|------|
| `viltrum.v` | App facade (`new`, routes, `listen`, `ws`, middleware helpers) |
| `engine/` | TCP accept, HTTP loop, `Conn`, upgrade match |
| `http/` | Parse/serialize, headers, Request/Response |
| `router/` | Method + path params + wildcards |
| `ws/` | RFC 6455 server framing |
| `staticf/` | Static file responses |
| `examples/` | Runnable demos |

## Common options

```v
import time
import viltrum { new, ServerOptions }

mut app := new()
app.server_options(ServerOptions{
	max_body_bytes:  1 << 20
	max_conns:       1024
	read_timeout:    30 * time.second
	idle_timeout:    60 * time.second
	handle_signals:  true // SIGINT/SIGTERM stop accept loop
	send_date:       true
	server_header:   'viltrum'
})
```

Defaults are conservative. Raise timeouts for long-lived WebSockets; see [ws.md](./ws.md).

## Next

- Routing and middleware: [request-response.md](./request-response.md)
- Deploy behind a proxy: [deploy.md](./deploy.md)
- WebSocket: [ws.md](./ws.md) · `v run examples/ws_echo`
