module viltrum

import time
import viltrum.engine
import viltrum.http1
import viltrum.router

// Viltrum is an HTTP/1.1 framework for V with its own engine: one epoll worker per
// CPU, and no allocation per request inside the framework.

pub const version = '1.13.0'

pub type Ctx = http1.Ctx
pub type Handler = fn (mut Ctx)

pub type Method = http1.Method
pub type Options = engine.Options
pub type TlsOptions = engine.TlsOptions
pub type Listener = engine.Listener

// FileOptions and StaticOptions tune Ctx.file and App.static_files.
pub type FileOptions = http1.FileOptions
pub type StaticOptions = http1.StaticOptions

// FormPart is one part of a multipart/form-data body (Ctx.form_file, Ctx.form_parts).
pub type FormPart = http1.FormPart

// Cookie is a Set-Cookie line for Ctx.set_cookie; see http1.Cookie for the defaults.
pub type Cookie = http1.Cookie
pub type SameSite = http1.SameSite

// Ws is one WebSocket connection inside its callbacks: send_text, send_binary,
// ping, close, subscribe, publish, id, protocol, worker_id, and `data` for the
// connection's own state.
pub type Ws = http1.Ws

// WsId names one WebSocket connection (Ws.id) for App.ws_send.
pub type WsId = http1.WsId

// WsMessage is one whole message; data is valid until the callback returns.
pub type WsMessage = http1.WsMessage

// WsHandler is what a WebSocket route does. Every callback runs on the worker that
// owns the connection, one at a time, so per-connection state needs no lock; like
// handlers, callbacks must not block.
pub struct WsHandler {
pub:
	// on_open runs after the 101 is sent; c is the upgrade request (params, headers).
	on_open fn (mut s Ws, mut c Ctx) = unsafe { nil }
	// on_message gets each message whole, fragments joined, text checked to be UTF-8.
	on_message fn (mut s Ws, m WsMessage) = unsafe { nil }
	// on_close runs once however the connection ends, with the Close code (1005 when
	// the Close had none, 1006 when there was no Close). Sends are dropped by then.
	on_close fn (mut s Ws, code int) = unsafe { nil }
	// max_message caps a message, fragments included; larger ones close with 1009.
	max_message int = 1024 * 1024
	// idle_timeout closes a connection that sent nothing for this long; 0 never does.
	idle_timeout time.Duration = 120 * time.second
	// protocols are the subprotocols spoken, preferred first (Sec-WebSocket-Protocol).
	protocols []string
	// check_origin, when set, refuses upgrades whose Origin it rejects with 403.
	// Browsers send Origin: set this for a browser-facing endpoint.
	check_origin fn (origin string) bool = unsafe { nil }
}

// Stream is one streaming response inside its callbacks: write, write_string, end,
// after, the Server-Sent Events helpers (event, event_id, comment, retry), subscribe,
// publish, publish_event, id, worker_id, and `data` for the stream's own state.
pub type Stream = http1.Stream

// StreamId names one stream (Stream.id) for App.stream_send and App.send_event.
pub type StreamId = http1.StreamId

// StreamHandler is what a streaming response does (Ctx.stream, Ctx.sse). Every
// callback runs on the worker that owns the connection, one at a time, so
// per-stream state needs no lock; like handlers, callbacks must not block.
//   on_open runs once the head is out; c is the request (params, headers).
//   on_drain runs once everything written so far is out: write the next piece of a
//     body generated as the client takes it, and end() after the last.
//   on_close runs once however the stream ends; writes are dropped by then.
//   heartbeat (SSE) sends a comment when nothing else went out for that long.
pub type StreamHandler = http1.StreamHandler

struct PendingRoute {
	method   Method
	pattern  string
	handlers []Handler
}

@[heap]
pub struct App {
mut:
	global []Handler
	routes []PendingRoute
	opts   engine.Options
	hub    &engine.Hub = engine.new_hub()
}

pub fn new() &App {
	return &App{}
}

// publish sends a text message to every WebSocket subscribed to topic (Ws.subscribe),
// on every worker. It may be called from any thread, handlers included; the message
// is copied once. Without a running server it is dropped.
pub fn (app &App) publish(topic string, text string) {
	if topic.len > 0 {
		app.hub.post(http1.ws_post(topic, http1.WsId{}, http1.WsId{}, http1.ws_text, text.str,
			text.len))
	}
}

pub fn (app &App) publish_binary(topic string, data []u8) {
	if topic.len > 0 {
		app.hub.post(http1.ws_post(topic, http1.WsId{}, http1.WsId{}, http1.ws_binary, data.data,
			data.len))
	}
}

// ws_send sends a text message to one WebSocket connection, from any thread. It is
// dropped when that connection has closed.
pub fn (app &App) ws_send(id WsId, text string) {
	app.hub.post(http1.ws_post('', id, http1.WsId{}, http1.ws_text, text.str, text.len))
}

pub fn (app &App) ws_send_binary(id WsId, data []u8) {
	app.hub.post(http1.ws_post('', id, http1.WsId{}, http1.ws_binary, data.data, data.len))
}

// stream_send writes data to one stream (Stream.id), from any thread. It is dropped
// when that stream has ended.
pub fn (app &App) stream_send(id StreamId, data []u8) {
	app.hub.post(http1.stream_post('', id, http1.StreamId{}, data.data, data.len))
}

// send_event sends one Server-Sent Event (see Stream.event) to one stream, from any
// thread.
pub fn (app &App) send_event(id StreamId, name string, data string) {
	if p := http1.sse_post('', id, http1.StreamId{}, '', name, data) {
		app.hub.post(p)
	}
}

// stream_publish writes data to every stream subscribed to topic (Stream.subscribe),
// on every worker, from any thread; WebSocket subscribers of the topic do not get it.
pub fn (app &App) stream_publish(topic string, data []u8) {
	if topic.len > 0 {
		app.hub.post(http1.stream_post(topic, http1.StreamId{}, http1.StreamId{}, data.data,
			data.len))
	}
}

// publish_event is stream_publish of one Server-Sent Event.
pub fn (app &App) publish_event(topic string, name string, data string) {
	if topic.len > 0 {
		if p := http1.sse_post(topic, http1.StreamId{}, http1.StreamId{}, '', name, data) {
			app.hub.post(p)
		}
	}
}

// server_options replaces the engine options (workers, limits, timeouts, Date, Server).
pub fn (mut app App) server_options(opts Options) {
	app.opts = opts
}

// use adds global middleware. It runs before every route, and before the 404 and
// 405 answers too.
pub fn (mut app App) use(mw Handler) {
	app.global << mw
}

// handle registers handlers for method + pattern. The last one answers the request;
// the ones before it are route middleware that call c.next().
pub fn (mut app App) handle(method Method, pattern string, handlers ...Handler) {
	app.routes << PendingRoute{
		method:   method
		pattern:  pattern
		handlers: handlers
	}
}

pub fn (mut app App) get(pattern string, handlers ...Handler) {
	app.handle(.get, pattern, ...handlers)
}

pub fn (mut app App) post(pattern string, handlers ...Handler) {
	app.handle(.post, pattern, ...handlers)
}

pub fn (mut app App) put(pattern string, handlers ...Handler) {
	app.handle(.put, pattern, ...handlers)
}

pub fn (mut app App) patch(pattern string, handlers ...Handler) {
	app.handle(.patch, pattern, ...handlers)
}

pub fn (mut app App) delete(pattern string, handlers ...Handler) {
	app.handle(.delete, pattern, ...handlers)
}

pub fn (mut app App) head(pattern string, handlers ...Handler) {
	app.handle(.head, pattern, ...handlers)
}

pub fn (mut app App) options(pattern string, handlers ...Handler) {
	app.handle(.options, pattern, ...handlers)
}

// ws serves WebSocket on GET pattern. Global middleware and mws run on the upgrade
// request first, so they can refuse it (auth) before h takes the connection over.
pub fn (mut app App) ws(pattern string, h WsHandler, mws ...Handler) {
	app.handle(.get, pattern, ...ws_chain(h, mws))
}

// static_files serves the files under dir at prefix, for GET and HEAD:
// app.static_files('/assets', './public') answers /assets/app.css with
// ./public/app.css. A directory serves its index.html; names with '.' or '..',
// and dotfiles unless opts.dotfiles, answer 404 (see Ctx.static_file), and files
// carry ETag and Last-Modified and honor conditional and range requests (Ctx.file).
pub fn (mut app App) static_files(prefix string, dir string, opts StaticOptions) {
	for m in [Method.get, .head] {
		app.handle(m, static_pattern(prefix), static_handler(dir, opts))
	}
}

fn static_pattern(prefix string) string {
	p := prefix.trim_right('/')
	return p + '/*filepath'
}

fn static_handler(dir string, opts StaticOptions) Handler {
	o := &StaticOptions{
		...opts
	}
	return fn [dir, o] (mut c Ctx) {
		c.static_file_at(dir, c.param('filepath') or { '' }, o)
	}
}

fn ws_chain(h WsHandler, mws []Handler) []Handler {
	hp := &http1.WsHandler{
		on_open:      http1.WsOpen(h.on_open)
		on_message:   http1.WsOnMessage(h.on_message)
		on_close:     http1.WsOnClose(h.on_close)
		max_message:  h.max_message
		idle_timeout: h.idle_timeout
		protocols:    h.protocols.clone()
		check_origin: http1.WsOrigin(h.check_origin)
	}
	mut chain := mws.clone()
	chain << fn [hp] (mut c Ctx) {
		c.ws_upgrade(hp)
	}
	return chain
}

pub struct Group {
mut:
	app    &App
	prefix string
	mws    []Handler
}

// group returns routes under prefix that share mws.
pub fn (mut app App) group(prefix string, mws ...Handler) Group {
	return Group{
		app:    app
		prefix: prefix.trim_right('/')
		mws:    mws
	}
}

pub fn (mut g Group) handle(method Method, pattern string, handlers ...Handler) {
	mut chain := g.mws.clone()
	chain << handlers
	g.app.handle(method, join_path(g.prefix, pattern), ...chain)
}

pub fn (mut g Group) get(pattern string, handlers ...Handler) {
	g.handle(.get, pattern, ...handlers)
}

pub fn (mut g Group) post(pattern string, handlers ...Handler) {
	g.handle(.post, pattern, ...handlers)
}

pub fn (mut g Group) put(pattern string, handlers ...Handler) {
	g.handle(.put, pattern, ...handlers)
}

pub fn (mut g Group) patch(pattern string, handlers ...Handler) {
	g.handle(.patch, pattern, ...handlers)
}

pub fn (mut g Group) delete(pattern string, handlers ...Handler) {
	g.handle(.delete, pattern, ...handlers)
}

pub fn (mut g Group) head(pattern string, handlers ...Handler) {
	g.handle(.head, pattern, ...handlers)
}

pub fn (mut g Group) options(pattern string, handlers ...Handler) {
	g.handle(.options, pattern, ...handlers)
}

pub fn (mut g Group) ws(pattern string, h WsHandler, mws ...Handler) {
	g.handle(.get, pattern, ...ws_chain(h, mws))
}

// static_files is App.static_files under the group's prefix, behind its middleware.
pub fn (mut g Group) static_files(prefix string, dir string, opts StaticOptions) {
	for m in [Method.get, .head] {
		g.handle(m, static_pattern(prefix), static_handler(dir, opts))
	}
}

fn join_path(prefix string, pattern string) string {
	if pattern == '' || pattern == '/' {
		return if prefix == '' { '/' } else { prefix }
	}
	return prefix + if pattern.starts_with('/') {
		pattern
	} else {
		'/' + pattern
	}
}

fn (app &App) build() !&router.Router {
	mut r := &router.Router{}
	for pr in app.routes {
		mut chain := app.global.clone()
		chain << pr.handlers
		r.add(pr.method, pr.pattern, to_chain(chain))!
	}
	if app.global.len > 0 {
		mut nf := app.global.clone()
		nf << Handler(not_found)
		r.on_404 = to_chain(nf)
		mut na := app.global.clone()
		na << Handler(method_not_allowed)
		r.on_405 = to_chain(na)
	}
	return r
}

fn not_found(mut c Ctx) {
	c.text(404, 'not found')
}

fn method_not_allowed(mut c Ctx) {
	c.set_allow()
	c.text(405, 'method not allowed')
}

// listen serves until SIGINT/SIGTERM (or Options.stop).
pub fn (app &App) listen(addr string) ! {
	r := app.build()!
	engine.serve(addr, r, app.engine_options())!
}

fn (app &App) engine_options() engine.Options {
	return engine.Options{
		...app.opts
		hub: app.hub
	}
}

// listen_tls serves HTTPS on addr until SIGINT/SIGTERM (or Options.stop). A
// certificate replaced on disk is picked up by new connections within a second.
pub fn (app &App) listen_tls(addr string, tls TlsOptions) ! {
	app.serve([Listener{
		addr: addr
		tls:  tls
	}])!
}

// serve runs several listeners, cleartext and TLS, on the same workers until
// SIGINT/SIGTERM (or Options.stop).
pub fn (app &App) serve(listeners []Listener) ! {
	r := app.build()!
	engine.serve_listeners(listeners, r, app.engine_options())!
}

// worker_count is how many workers listen starts; size per-worker state with it and
// index it with c.worker_id().
pub fn (app &App) worker_count() int {
	return engine.worker_count(app.opts.workers)
}

// handle_raw serves raw request bytes in-process and returns the raw response bytes.
// Meant for tests: it rebuilds the router on every call.
pub fn (app &App) handle_raw(raw string) !string {
	r := app.build()!
	mut w := engine.new_worker(r, Options{
		...app.opts
		send_date: false
	}, 0)
	mut c := engine.new_conn()
	unsafe { c.rbuf.push_many(raw.str, raw.len) }
	w.process_waiting(mut c)
	return c.wbuf.bytestr()
}

// to_chain converts to the router's handler type (viltrum.Handler is a distinct fn alias).
fn to_chain(hs []Handler) []http1.Handler {
	mut out := []http1.Handler{cap: hs.len}
	for h in hs {
		out << http1.Handler(h)
	}
	return out
}
