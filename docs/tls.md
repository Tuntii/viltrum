# TLS (`https://`)

Viltrum serves HTTPS from the same epoll workers that serve cleartext, and both can run in one process. A
reverse proxy in front stays a first-class deploy (see [deploy.md](./deploy.md)); in-process TLS is for when
you would rather not run one.

## Quick start

```bash
bash scripts/dev-cert.sh          # writes certs/dev.crt + certs/dev.key (self-signed, dev only)
v run examples/https
curl -k https://127.0.0.1:8443/
```

```v
mut app := viltrum.new()
app.get('/', fn (mut c viltrum.Ctx) {
	c.text(200, 'ok\n')
})
app.listen_tls('127.0.0.1:8443', viltrum.TlsOptions{
	cert_file: 'certs/dev.crt'
	key_file:  'certs/dev.key'
})!
```

Cleartext and TLS together, on the same workers:

```v
app.serve([
	viltrum.Listener{
		addr: '0.0.0.0:8080'
	},
	viltrum.Listener{
		addr: '0.0.0.0:8443'
		tls:  viltrum.TlsOptions{
			cert_file: '/etc/viltrum/server.crt'
			key_file:  '/etc/viltrum/server.key'
		}
	},
])!
```

## API

| Symbol | Role |
|--------|------|
| `TlsOptions{ cert_file, key_file }` | PEM certificate chain (leaf first) and unencrypted private key |
| `app.listen_tls(addr, tls)` | serve HTTPS on one address until SIGINT/SIGTERM or `Options.stop` |
| `Listener{ addr, tls }` | one address; `tls` unset means cleartext |
| `app.serve(listeners)` | several listeners, cleartext and TLS, on the same workers |

The certificate and key are loaded and checked against each other before any socket opens, so a wrong path or a
key that does not belong to the certificate fails at startup.

## Certificate reload

Replace the files and new connections get the new certificate within about a second. No signal, nothing to
enable.

- Every worker checks both files once a second (inode, size and mtime). The certificate is picked per
  handshake, so live connections keep the session they have.
- A pair that does not load is skipped, and the last good one keeps serving. That covers a cert and key renamed
  into place one after the other: the moment between the two renames sees a mismatched pair and ignores it.
  The failure is logged once, and the pair is retried when a file changes again.
- Files are opened by path each time, so renaming a new file onto the path (what certbot and most tools do) is
  picked up.

## Policy

| | |
|-|-|
| Versions | TLS 1.3 preferred, TLS 1.2 minimum (mbedtls 3 has no SSLv3, TLS 1.0 or 1.1) |
| Suites | AEAD only: AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305, with ECDHE in TLS 1.2 |
| Groups | x25519, secp256r1, secp384r1 |
| ALPN | `http/1.1` (viltrum does not speak HTTP/2) |
| SNI | not required; the listener's certificate is served either way |
| Session resumption | off: no tickets, every connection does a full handshake |
| Close | `close_notify` before the socket closes |

The handshake runs under `Options.read_timeout`, the same clock as a partly received request.

## How it works

The crypto is mbedtls 3.6, the copy that ships with V (`thirdparty/mbedtls`, behind `net.mbedtls`). Nothing
to install. viltrum runs it non-blocking inside the epoll loop: each worker has its own config, random generator
and certificate, and each pooled connection keeps its TLS session and reuses it for the next connection. The
request path still allocates nothing; a test in CI holds it to that over TLS too.

Design notes and trade-offs: [design/1.x-tls.md](./design/1.x-tls.md).

## Cost

mbedtls is slower than OpenSSL at bulk AES-GCM. On a small 8-vCPU VM, keep-alive `GET` over TLS ran at about
half the cleartext rate, and a 10 KB echo at about a quarter. Each TLS connection holds about 50 KB for record
buffers. If TLS throughput is your bottleneck, terminate at a proxy.

## Not supported

- ACME / Let's Encrypt inside viltrum (use certbot or the proxy's ACME and point `TlsOptions` at the files)
- Client certificates (mTLS)
- Encrypted private keys
- HTTP/2 over ALPN
- WSS: WebSocket is not on the 1.0 core yet
