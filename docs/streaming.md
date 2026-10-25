# Streaming responses and Server-Sent Events

A streaming response has a body written over time, after the handler has returned: live updates, progress,
tokens as a model produces them, or a large body generated as the client takes it. The handler answers with
`c.stream(...)` or `c.sse(...)` and a `StreamHandler`. From then on, the stream belongs to the handler's
callbacks. They run on the worker that owns the connection, one at a time, so per-stream state needs no lock.
Like handlers, they must not block.

The same handler serves HTTP/1.1 and HTTP/2 ([docs/http2.md](http2.md)). Over HTTP/2 each stream is one
HTTP/2 stream, so one connection carries many of them beside its other requests. That matters for SSE in
browsers, which open at most six HTTP/1.1 connections per origin, and so at most six `EventSource`s; over
HTTP/2 the limit is the 128 concurrent streams the server announces. See
[The connection while it streams](#the-connection-while-it-streams) for what differs.

## Server-Sent Events

```v
import time
import viltrum

fn tick(mut s viltrum.Stream, n u64) {
	if n == 0 {
		s.event('done', '')
		s.end()
		return
	}
	s.event('tick', 'left ${n}')
	s.after(1000, tick, n - 1)
}

const clock = &viltrum.StreamHandler{
	on_open: fn (mut s viltrum.Stream, mut c viltrum.Ctx) {
		s.retry(3000) // how long the browser waits before it reconnects
		s.after(1000, tick, 10)
	}
	heartbeat: 15 * time.second
}

app.get('/clock', fn (mut c viltrum.Ctx) {
	c.sse(clock)
})
```

In the browser: `new EventSource('/clock').addEventListener('tick', e => console.log(e.data))`.

`c.sse(h)` answers `200` with `Content-Type: text/event-stream`, `Cache-Control: no-cache` and
`X-Accel-Buffering: no`. Without the last one, nginx would buffer the stream. The `Stream` writes events in the
text/event-stream format:

| Call | Sends |
|------|-------|
| `s.event(name, data)` | One event. `name` is its type (`''` for the default, `message`); `data` goes out as one `data:` line per line it holds (CRLF, CR and LF all split lines) |
| `s.event_id(id, name, data)` | The same with an `id:`, which the browser sends back as `Last-Event-ID` when it reconnects |
| `s.comment(text)` | A comment, which clients ignore |
| `s.retry(ms)` | The reconnection delay |

An event whose name holds CR or LF, or whose id holds CR, LF or NUL, is not sent. The client could not be told
it whole.

`heartbeat` sends a comment whenever nothing else went out for that long, checked once a second. Proxies and
load balancers close idle connections; a heartbeat keeps the stream open through them, and also finds clients
that went away without closing.

On reconnect, the browser sends the last id it saw: read it in `on_open` with `c.header('last-event-id')` and
send what it missed.

## Plain streams

`c.stream(status, content_type, h)` answers with any status and type. What the callbacks write is the body, as
it is:

| Call | Does |
|------|------|
| `s.write(b)`, `s.write_string(t)` | Send the next piece of the body |
| `s.end()` | Finish the body |
| `s.after(ms, cb, arg)` | Run `cb(mut s, arg)` on this stream no sooner than `ms` on, unless the stream ends first. A stream may have several timers |
| `s.data` | This stream's own state, as a `voidptr`: set it in `on_open`, every later callback sees it |
| `s.id()` | Names the stream for sends from elsewhere (below) |

The `StreamHandler` callbacks:

| Callback | Runs |
|----------|------|
| `on_open(mut s, mut c)` | Once the head is out; `c` is the request (params, headers, query) |
| `on_drain(mut s)` | Once everything written so far is out: write the next piece of a body generated as the client takes it, and `end()` after the last |
| `on_close(mut s)` | Once, however the stream ends: `end()`, the client going away, a slow client cut off. Writes are dropped by then; publishes still go out |

### A body generated as the client takes it

`on_drain` is the pull side. It runs when the socket has taken everything written so far (over HTTP/2: when
the stream has nothing left that its flow-control window holds back), so a slow client slows the generator
instead of filling memory:

```v
const export_csv = &viltrum.StreamHandler{
	on_open: fn (mut s viltrum.Stream, mut c viltrum.Ctx) {
		s.write_string('id,name\n')
	}
	on_drain: fn (mut s viltrum.Stream) {
		n := u64(s.data) // the next row
		if n == rows.len {
			s.end()
			return
		}
		write_row(mut s, rows[n])
		s.data = voidptr(n + 1)
	}
}
```

A client that takes everything at once does not hold the worker: after 256 KiB in one go, the stream waits
for the next turn of the event loop.

## Sending from elsewhere

Any thread can write to a stream, or to every stream on a topic. The bytes go through the same hub as
WebSocket messages (one inbox per worker, [docs/ws.md](ws.md)), are copied once, and are written by the
stream's own worker:

| Call | Sends |
|------|-------|
| `app.stream_send(id, bytes)` | To one stream (`s.id()`) |
| `app.send_event(id, name, data)` | One SSE event to one stream |
| `app.stream_publish(topic, bytes)` | To every stream subscribed to `topic` |
| `app.publish_event(topic, name, data)` | One SSE event to every subscriber |
| `s.subscribe(topic)`, `s.unsubscribe(topic)` | Inside callbacks |
| `s.publish(topic, bytes)`, `s.publish_event(topic, name, data)` | Inside callbacks: to every subscriber but this stream |

Topics share their names with WebSocket topics, but each kind gets only its own messages: a stream publish
never reaches a WebSocket, and `app.publish` never reaches a stream. A send to a stream that has ended is
dropped. A stream that ends leaves its topics.

```v
// a worker thread produces tokens; each goes to the stream that asked for them
spawn fn [app, id] () {
	for tok in generate() {
		app.send_event(id, 'token', tok)
	}
	app.send_event(id, 'done', '')
}()
```

## The connection while it streams

- **Framing.** HTTP/1.1 clients get the body chunked (`Transfer-Encoding: chunked`). Each write is one chunk.
  After `end()`, the connection serves the client's next request. HTTP/1.0 clients get the bytes as they are,
  and the connection closes after `end()`. `Connection: close` from the client also waits for the end.
  HTTP/2 clients get the head as HEADERS and the writes as DATA, as the stream's and the connection's windows
  allow; `end()` sets END_STREAM.
- **Pipelined requests.** On HTTP/1.1, requests pipelined behind a stream wait until it ends, as they do behind
  a deferred response (`c.after`). On HTTP/2 nothing waits: the connection's other streams are served
  meanwhile.
- **Cancel.** An HTTP/2 client that resets the stream (RST_STREAM) ends it as a client that goes away does:
  `on_close` runs, its timers are dropped, it leaves its topics.
- **HEAD and bodiless statuses.** A `HEAD` request, or a status without a body (`204`, `304`), gets the head
  alone; the callbacks do not run.
- **Middleware.** Middleware that rewrites bodies leaves a stream alone. `gzip` does not compress it.
- **Timeouts.** A stream runs as long as its handler likes; the idle and read timeouts do not apply, since the
  client is expected to stay quiet. The write timeout does apply: output that stops moving for that long closes
  the connection (over HTTP/2, output its windows hold back as well as a full socket).
- **Slow clients.** Writes that are not pulled by `on_drain` (timers, sends, publishes) can outrun a client. One
  that lets more than four times `max_pending` pile up unread is closed, as for WebSocket. Over HTTP/2 the
  count is per stream, and only that stream ends: it is reset with CANCEL, the connection goes on.
- **Input.** Input the client sends during a stream waits, up to the read buffer's limit; past it the connection
  closes.

Nothing on this path allocates once the buffers are warm: a timer's event and a send to the stream are held to
the zero-allocation gate in CI, over HTTP/1.1 and HTTP/2.
