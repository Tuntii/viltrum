# Calling other services: `c.fetch`

A handler that needs another HTTP service (an internal API, a data source, the next hop of a proxy) asks it
with `c.fetch` and answers when the reply comes in. The worker is not held meanwhile: it goes on serving its
other connections, and the reply's callback runs on the same worker, like the callback of
[`c.after`](request-response.md). Connections to each upstream are kept alive and pooled per worker, and once
the pool is warm a fetch allocates nothing.

Linux only, like the rest of the engine. Upstreams speak cleartext HTTP/1.1; `https://` upstreams come later
(see the [design](design/1.x-client.md)).

## Declare the upstream, then fetch

```v
import viltrum

fn main() {
	mut app := viltrum.new()
	users := app.upstream('http://127.0.0.1:9000', viltrum.UpstreamOptions{})!

	app.get('/users/:id', fn [users] (mut c viltrum.Ctx) {
		c.fetch(users, .get, c.path(), on_user, 0)
	})
	app.listen(':8080')!
}

fn on_user(mut c viltrum.Ctx, arg u64) {
	r := c.fetched()
	if r.err != .none {
		c.text(502, 'users service: ${r.err}')
		return
	}
	c.bytes(r.status, c.fetched_header('content-type') or { 'application/json' }, r.body)
}
```

- `app.upstream(url, opts)` takes `http://host[:port]`, without a path. The host is resolved **once, at
  startup**: no DNS lookups while serving. Declare every upstream before `listen`.
- `c.fetch(up, method, target, cb, arg)` sends `method target` to the upstream with a `Host` header. The handler
  returns at once; `cb(mut c, arg)` runs exactly once, with the reply or with the error that ended the wait.
- Before the handler returns, `c.fetch_body(data)` sets a request body (`Content-Length` is added) and
  `c.fetch_header(name, value)` adds a header, at most 8. `Host`, `Content-Length`, `Transfer-Encoding`,
  `Connection`, `Keep-Alive`, `Proxy-Connection`, `TE`, `Upgrade` and `Expect` are the engine's to write and
  are dropped. `target`, `data` and header values may be views of
  the incoming request (`c.path()`, `c.body()`, `c.header(...)`): they are copied when the handler returns.
- In the callback, `c.fetched()` is `{err, status, body}` and `c.fetched_header(name)` reads a reply header.
  Both point into the upstream connection's buffer and are valid until the callback returns. Clone what you
  keep.

As with `after`, the incoming request is gone by the time `cb` runs: path, params, headers and body read
empty. Pass what the callback needs in `arg`. The callback may write the response, `fetch` again (calls in a
chain), or call `after`. A response written in the handler after `fetch` is dropped: the callback answers
the request.

```v
// forward a JSON body and the caller's auth header
fn create(mut c viltrum.Ctx) {
	c.fetch(orders, .post, '/orders', on_created, 0)
	c.fetch_body(c.body())
	c.fetch_header('Content-Type', 'application/json')
	c.fetch_header('Authorization', c.header('authorization') or { '' })
}
```

## Errors

| `err` | When |
|-------|------|
| `.none` | A whole reply. Any status the upstream sent, 4xx and 5xx included, is in `status`. |
| `.connect` | The upstream refused the connection or could not be reached. |
| `.timeout` | No whole reply within `timeout`. Timeouts are checked once a second. |
| `.closed` | The upstream closed before the reply was whole. |
| `.protocol` | Not a valid HTTP/1.1 reply. |
| `.too_big` | The reply is larger than `max_reply`. |
| `.busy` | Every connection and the queue are taken (`max_conns`, `max_queue`). |

A request whose method may be sent twice (GET, HEAD, PUT, DELETE, OPTIONS) is sent once more on a new
connection when its pooled connection turns out closed before any byte of the reply arrived: the upstream may
close an idle connection just as it is taken. Other methods answer `.closed`.

## Options

`viltrum.UpstreamOptions`; the counts are per worker.

| Field | Default | |
|-------|---------|--|
| `max_conns` | 64 | Connections open to the upstream. |
| `max_queue` | 1024 | Fetches that wait for a connection; past it, `.busy` at once. |
| `timeout` | 10 s | From the fetch to the whole reply, the queue included. |
| `idle_timeout` | 30 s | A pooled connection unused this long is closed. |
| `max_reply` | 1 MiB | Head and body together. |

## The request while it waits

On HTTP/1.1 the connection waits for the reply, and requests pipelined behind it wait their turn, as behind
`after`. Over HTTP/2 only the request's own stream waits; the connection's other streams are answered
meanwhile. A client that closes (or resets the stream) while a fetch is out does not stop the fetch: its
reply is read and dropped, and the connection goes back to the pool.

## Not supported yet

`https://` upstreams, choosing the URL per request (or DNS while serving), fetching from outside a handler,
several fetches in parallel from one request (chaining them works), streaming reply bodies, redirects,
cookies, and compressed replies (no `Accept-Encoding` is sent). The [design](design/1.x-client.md) says why.
`handle_raw` and other tests without an event loop reach no upstream: a fetch there answers `.timeout` at once.
