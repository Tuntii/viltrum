# Deploy (cleartext behind a reverse proxy)

Viltrum speaks **cleartext HTTP/1.1** on TCP. For TLS at the edge, put **Caddy**, **nginx**, or another reverse proxy in front. In-process TLS is planned (roadmap v0.6), not required for production-shaped deploys.

## Recommended shape

```
client ──HTTPS──▶ reverse proxy ──HTTP──▶ viltrum :8080
```

Bind Viltrum to loopback or a private interface:

```v
app.listen('127.0.0.1:8080')!
```

## What the proxy must get right

| Concern | Guidance |
|---------|----------|
| **Host** | Forward the original host (`Host` / `X-Forwarded-Host` as you prefer). Viltrum requires `Host` on HTTP/1.1 by default. |
| **Timeouts** | Proxy idle/read timeouts should be ≥ app `idle_timeout` / `read_timeout` (defaults 60s / 30s) or intentionally shorter if you want the proxy to cut first. |
| **Body size** | Proxy `client_max_body_size` (or equivalent) should match or sit under `max_body_bytes` (default 1 MiB) so errors are consistent. |
| **WebSockets (`ws://`)** | Proxy must allow `Upgrade` / `Connection` hop-by-hop headers and long-lived connections. See [ws.md](./ws.md). |
| **HTTP/2 at edge** | Fine. Proxy terminates H2 and talks HTTP/1.1 to Viltrum. |

## Caddy (sketch)

```caddyfile
example.com {
	reverse_proxy 127.0.0.1:8080
}
```

## nginx (sketch)

HTTP only:

```nginx
server {
	listen 443 ssl;
	server_name example.com;

	location / {
		proxy_pass http://127.0.0.1:8080;
		proxy_http_version 1.1;
		proxy_set_header Host $host;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;
		proxy_read_timeout 60s;
	}
}
```

WebSocket path (same upstream; hop-by-hop upgrade headers required):

```nginx
location /ws {
	proxy_pass http://127.0.0.1:8080;
	proxy_http_version 1.1;
	proxy_set_header Host $host;
	proxy_set_header Upgrade $http_upgrade;
	proxy_set_header Connection "upgrade";
	proxy_read_timeout 3600s;
}
```

## Process model

- One process, one listen address (multi-listener is backlog).
- Graceful stop: SIGINT/SIGTERM closes the listener; existing conns are not given a long drain window in 0.3.x.
- Run under your supervisor (`systemd`, container restart policy, etc.).

## Trust and headers

Viltrum does **not** interpret `X-Forwarded-*` for security decisions. If you build auth or rate limits on client IP, strip or overwrite untrusted hop headers at the proxy and document which hop you trust.

## Related

- Docs index: [README.md](./README.md)
- Connection lifecycle: [connection.md](./connection.md)
- WebSocket: [ws.md](./ws.md)
- Product plan: [../ROADMAP.md](../ROADMAP.md)
