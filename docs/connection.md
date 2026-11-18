# Connections

- One worker per CPU in the process affinity mask (`Options.workers` or `VILTRUM_WORKERS` override), each with
  its own `SO_REUSEPORT` listener and epoll loop.
- A connection holds buffers only while something is in them. The worker lends it an 8 KiB read and a 16 KiB
  write buffer when there is something to read or write, and takes each back once it is empty: once the
  request is answered and the response is out. A connection waiting on its client (keep-alive), on a timer
  (`c.after`), or on a topic costs its `Conn` alone, a few hundred bytes, and the kernel's socket. Under load
  the pools stay at a few buffers per worker. A read buffer one request grew stays in the pool up to 64 KiB.
  A write buffer one response grew, up to 256 KiB, is kept apart, at most 32 per worker, for HTTP/2, whose
  connections take one before they answer; the rest go back to the GC. TLS sessions borrow their record
  buffers the same way, and mbedtls' context exists only while mbedtls has the session (TLS 1.2, or a
  handshake viltrum's own TLS 1.3 code passes on).
- Every complete request in a read is served, and the responses go out in one `send`. Processing pauses once
  `Options.max_pending` (1 MiB) of output waits; reading pauses while output is pending. HTTP/2 answers a
  read's requests 32 KiB of output at a time; the rest of the read waits for the next round. Over TLS 1.3 the
  session takes what it encrypts, so a connection whose socket is full holds its encrypted records alone,
  not the write buffer too.
- Limits live under `Options.limits`: `max_header_bytes` 64 KiB (431), `max_body_bytes` 1 MiB (413),
  `max_headers` 32 (431). `Options.max_conns` (503 and close).
- Timeouts: `read_timeout` 30 s from a request's first byte, `idle_timeout` 60 s between requests,
  `write_timeout` 30 s without write progress.
- Framing and parse errors answer 4xx after any earlier pipelined responses, then close. A request too large
  for the limits answers 413 whether its `Content-Length` says so or a chunked body grows past them; a
  `Content-Length` past what an i64 holds is malformed (400). A head past `max_header_bytes` answers 400 when
  its request line has no space yet (no method), 414 when the request line is still unfinished, 431 otherwise.
- The parser holds requests to RFC 9112 where a front proxy and the server could read one differently, and
  answers 400 for: a request line that is not ASCII (raw UTF-8 in the target must be percent-encoded); a
  version that is not `HTTP/` DIGIT `.` DIGIT (a well-formed one other than 1.x is 505); asterisk-form with a
  method other than OPTIONS; a `Host` that is empty or not uri-host [":" port] (userinfo, a path, a list);
  whitespace between a chunk size and its CRLF, chunk extensions that are not `;name[=token or
  "quoted"]`. A chunked body whose framing passes 16 KiB and outweighs its data (1-byte chunks) is 413. `OPTIONS *` answers 200 with no body. HttpArena's compliance column runs Http11Probe against
  these rules.
- Lingering close: when the client may still be sending (a refused request, requests pipelined behind a
  close), the engine sends the response, shuts its side, and reads and drops input until the client closes,
  5 s pass without input, or 30 s in all; meanwhile the socket's receive buffer is cut to 16 KiB, so a
  client that floods slows to what is read instead of filling kernel memory. Closing at once would answer the unread input with a reset, which
  can destroy the response before a client still writing its upload reads it.
- SIGINT/SIGTERM stop accepting; open connections are closed within a second.
