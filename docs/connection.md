# Connections

- One worker per CPU in the process affinity mask (`Options.workers` or `VILTRUM_WORKERS` override), each with
  its own `SO_REUSEPORT` listener and epoll loop.
- Each connection keeps an 8 KiB read and 16 KiB write buffer for its life; they grow only for larger messages
  and shrink back when the connection closes.
- Every complete request in a read is served, and the responses go out in one `send`. Processing pauses once
  `Options.max_pending` (1 MiB) of output waits; reading pauses while output is pending.
- Limits live under `Options.limits`: `max_header_bytes` 64 KiB (431), `max_body_bytes` 1 MiB (413),
  `max_headers` 32 (431). `Options.max_conns` (503 and close).
- Timeouts: `read_timeout` 30 s from a request's first byte, `idle_timeout` 60 s between requests,
  `write_timeout` 30 s without write progress.
- Framing and parse errors answer 4xx after any earlier pipelined responses, then close. A request too large
  for the limits answers 413 whether its `Content-Length` says so or a chunked body grows past them.
- Lingering close: when the client may still be sending (a refused request, requests pipelined behind a
  close), the engine sends the response, shuts its side, and reads and drops input until the client closes,
  5 s pass without input, or 30 s in all. Closing at once would answer the unread input with a reset, which
  can destroy the response before a client still writing its upload reads it.
- SIGINT/SIGTERM stop accepting; open connections are closed within a second.
