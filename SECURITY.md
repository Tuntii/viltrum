# Security

Viltrum parses untrusted bytes off the wire, so parser, framing, and WebSocket bugs are security bugs.

## Reporting

Please **do not** open a public issue. Use GitHub's private report:
[Report a vulnerability](https://github.com/Tuntii/viltrum/security/advisories/new).

Include a raw request (or byte dump) that reproduces it and the Viltrum version / commit.
Expect a first reply within a few days. Fixes ship as a patch release with credit unless you ask otherwise.

## In scope

- Request smuggling / framing disagreements (Content-Length, Transfer-Encoding, header parsing), over HTTP/1.1 and HTTP/2
- Crashes or panics reachable from a remote peer (HTTP/1.1, HTTP/2 and HPACK, multipart, WebSocket frames)
- Limit bypasses (`max_body_bytes`, header size, timeouts, `max_conns`)
- TLS: the TLS 1.3 records and handshake, certificate handling, WSS
- The HTTP client: replies from an upstream that crash a worker, stall it, or reach another request's handler

## Supported versions

Only the latest release line gets fixes.
