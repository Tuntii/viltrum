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
| ALPN | `http/1.1`; `h2` first on a listener with `http2` set ([http2.md](./http2.md)) |
| SNI | not required; the listener's certificate is served either way |
| Session resumption | off: no tickets, every connection does a full handshake |
| Key update | the server rekeys after 2^24 records under one key (RFC 8446 5.5), and when the client asks; a client that asks more than 1024 times on one connection is cut off |
| Close | `close_notify` before the socket closes |

The handshake runs under `Options.read_timeout`, the same clock as a partly received request.

## How it works

TLS runs non-blocking inside the epoll loop: each worker has its own random generator and certificate, and
each pooled connection keeps its TLS session state and reuses it for the next connection. The request path
still allocates nothing; a test in CI holds it to that over TLS too.

Three layers, by where the CPU went:

- **The handshake** for TLS 1.3 with an X25519 key share, AES-128-GCM and an RSA certificate (what curl,
  OpenSSL and Python offer by default) is viltrum's own: X25519 and RSA-PSS signing in C, the key
  schedule after RFC 8446, checked against RFC 8448's trace. It takes about half the CPU mbedtls did (3.7 ms
  against 7.4 ms per handshake on a small VM). See [design/1.x-tls-handshake.md](./design/1.x-tls-handshake.md).
- **Every other handshake** (TLS 1.2, P-256 key shares, ECDSA certificates, ChaCha20 or AES-256 as the only
  suite) runs on mbedtls 3.6, the copy that ships with V (`thirdparty/mbedtls`, behind `net.mbedtls`). Nothing
  to install.
- **Records** of TLS 1.3 AES-GCM sessions are sealed and opened by viltrum's own AES-GCM on AES-NI and PCLMUL;
  TLS 1.2 and ChaCha20 sessions stay on mbedtls.

A handshake's expensive step runs one per turn of a worker's loop, with the requests that are ready served in
between, so a burst of new connections does not hold up the open ones.

Design notes and trade-offs: [design/1.x-tls.md](./design/1.x-tls.md).

## Cost

Each TLS connection holds about 50 KB for record buffers. The gcc build gets the fast paths above; a tcc build
(V's default for `v run`) has no 128-bit integers and does all of TLS on mbedtls. Build with `-prod` or
`-cc gcc` for production.

## Not supported

- ACME / Let's Encrypt inside viltrum (use certbot or the proxy's ACME and point `TlsOptions` at the files)
- Client certificates (mTLS)
- Encrypted private keys
