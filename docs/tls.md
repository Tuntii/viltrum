# TLS (`https://`) and WSS (`wss://`)

In-process TLS for single-binary demos and simple deploys. Reverse-proxy TLS remains first-class (see [deploy.md](./deploy.md)).

**Backend:** V stdlib `net.mbedtls` only (no OpenSSL server path, no ACME, no mTLS in this release).

## Quick start

```bash
bash scripts/dev-cert.sh          # writes certs/dev.crt + certs/dev.key
v run examples/https_hello
curl -k https://127.0.0.1:8443/
```

```v
import viltrum { new, text, Request, Response, TlsOptions }

mut app := new()
app.get('/', fn (req Request) Response {
	return text(200, 'ok\n')
})
app.listen_tls('127.0.0.1:8443', TlsOptions{
	cert_file: 'certs/dev.crt'
	key_file:  'certs/dev.key'
})!
```

## WSS

Same WebSocket stack as cleartext (`app.ws`). Listen with `listen_tls`:

```bash
v run examples/wss_echo
websocat -k wss://127.0.0.1:8444/ws
```

Browsers need a trusted cert or a local exception; self-signed is fine for tooling (`websocat -k`, `curl -k`).

## API

| Symbol | Role |
|--------|------|
| `TlsOptions{ cert_file, key_file }` | PEM paths (required) |
| `app.listen_tls(addr, tls)` | HTTPS accept loop; WSS if `app.ws` is registered |
| `engine.listen_and_serve_tls_full(...)` | Advanced / tests |

Empty or missing paths return an error **before** bind.

## Architecture

All post-accept I/O goes through `engine.Conn` (TCP or SSL). HTTP keep-alive, `app.upgrade`, and `app.ws` share one path. Cipher/version policy is mbedtls/V defaults; Viltrum does not pin ciphers.

SSL write deadlines are not available in mbedtls’s API; rely on read timeout and OS TCP.

## Non-goals (this ship)

- ACME / Let’s Encrypt inside Viltrum
- mTLS / client cert auth
- Hot-reload certs
- HTTP/2
- OpenSSL (`-d use_openssl`) server listen

## Production note

For heavy edge TLS, terminate at **Caddy** or **nginx** and talk cleartext to Viltrum on loopback. In-process TLS is optional, not a replacement for a mature edge proxy.

## Related

- Design contract: [design/v0.6-tls-wss.md](./design/v0.6-tls-wss.md)
- WebSocket: [ws.md](./ws.md)
- Deploy / proxy: [deploy.md](./deploy.md)
