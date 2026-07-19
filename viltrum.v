module viltrum

// Viltrum HTTP App facade.
// v0.4: connection hijack / upgrade on engine.Conn.
// v0.5: first-party WebSocket via app.ws on the same Conn path.

import time
import viltrum.engine
import viltrum.http
import viltrum.router
import viltrum.staticf
import viltrum.ws

pub type Request = http.Request
pub type Response = http.Response
pub type Handler = fn (req http.Request) http.Response
pub type Middleware = fn (next Handler) Handler
pub type ServerOptions = engine.ServerOptions
// Conn is the upgrade/hijack stream (engine.Conn). Use this in UpgradeFn handlers.
pub type Conn = engine.Conn
// UpgradeFn takes over the connection after a matched app.upgrade route.
pub type UpgradeFn = fn (mut c Conn, req Request)
// WsSocket is the server-side WebSocket after 101.
pub type WsSocket = ws.Socket
// WsHandler runs after a successful WebSocket handshake.
pub type WsHandler = fn (mut s WsSocket)
// WsOptions configures limits, auto-pong, subprotocol, origin check.
pub type WsOptions = ws.Options

pub struct App {
mut:
	router      router.Router
	middlewares []Middleware
	upgrades    []engine.UpgradeRoute
	ctx         voidptr
	opts        engine.ServerOptions
}

pub fn new() App {
	return App{
		router:   router.Router.new()
		upgrades: []engine.UpgradeRoute{}
		ctx:      unsafe { nil }
		opts:     engine.ServerOptions{}
	}
}

pub fn (mut app App) set_ctx(ptr voidptr) {
	app.ctx = ptr
}

// server_options sets engine limits/timeouts (not the HTTP OPTIONS method).
pub fn (mut app App) server_options(opts engine.ServerOptions) {
	app.opts = opts
}

pub fn (mut app App) get(pattern string, handler Handler) {
	app.router.get(pattern, handler)
}

pub fn (mut app App) post(pattern string, handler Handler) {
	app.router.post(pattern, handler)
}

pub fn (mut app App) put(pattern string, handler Handler) {
	app.router.put(pattern, handler)
}

pub fn (mut app App) delete(pattern string, handler Handler) {
	app.router.delete(pattern, handler)
}

pub fn (mut app App) patch(pattern string, handler Handler) {
	app.router.patch(pattern, handler)
}

// options registers an HTTP OPTIONS route (use cors() for simple preflight).
pub fn (mut app App) options(pattern string, handler Handler) {
	app.router.options(pattern, handler)
}

pub fn (mut app App) head(pattern string, handler Handler) {
	app.router.head(pattern, handler)
}

pub fn (mut app App) route(method string, pattern string, handler Handler) {
	app.router.add(method, pattern, handler)
}

pub fn (mut app App) use(mw Middleware) {
	app.middlewares << mw
}

// upgrade registers a connection take-over handler for method + path pattern.
// When matched, the HTTP keep-alive loop stops and `handler` owns the Conn.
// Global middleware does not run on upgrade routes. See docs/upgrade.md.
pub fn (mut app App) upgrade(method string, pattern string, handler UpgradeFn) {
	// Adapt viltrum.UpgradeFn → engine.UpgradeFn (same shape, distinct aliases in V).
	h := handler
	app.upgrades << engine.UpgradeRoute{
		method:  method.to_upper()
		pattern: pattern
		handler: fn [h] (mut c engine.Conn, req http.Request) {
			h(mut c, req)
		}
	}
}

// ws registers a cleartext WebSocket route (RFC 6455) on GET + pattern.
// Handshake, framing, and limits live in viltrum.ws; built on app.upgrade.
// See docs/ws.md.
pub fn (mut app App) ws(pattern string, handler WsHandler) {
	app.ws_opts(pattern, ws.Options{}, handler)
}

// ws_opts is ws with explicit Options (message limits, subprotocol, origin check).
pub fn (mut app App) ws_opts(pattern string, opts WsOptions, handler WsHandler) {
	h := handler
	// Adapt viltrum.WsHandler → ws.Handler (same shape; V treats module aliases distinctly).
	up := ws.make_upgrade(opts, fn [h] (mut s ws.Socket) {
		h(mut s)
	})
	app.upgrades << engine.UpgradeRoute{
		method:  'GET'
		pattern: pattern
		handler: up
	}
}

// chain applies route-level middleware (first = outermost), then handler.
pub fn chain(mws []Middleware, handler Handler) Handler {
	mut h := handler
	for i := mws.len - 1; i >= 0; i-- {
		h = mws[i](h)
	}
	return h
}

// Mount is a prefixing route builder for App.mount.
pub struct Mount {
mut:
	prefix string
	r      &router.Router
	mws    []Middleware
}

pub fn (mut app App) mount(prefix string, setup fn (mut m Mount)) {
	mut m := Mount{
		prefix: http.normalize_path(prefix)
		r:      &app.router
		mws:    []Middleware{}
	}
	setup(mut m)
}

pub fn (mut m Mount) use(mw Middleware) {
	m.mws << mw
}

pub fn (mut m Mount) get(pattern string, handler Handler) {
	m.r.get(join_mount(m.prefix, pattern), m.wrap(handler))
}

pub fn (mut m Mount) post(pattern string, handler Handler) {
	m.r.post(join_mount(m.prefix, pattern), m.wrap(handler))
}

pub fn (mut m Mount) put(pattern string, handler Handler) {
	m.r.put(join_mount(m.prefix, pattern), m.wrap(handler))
}

pub fn (mut m Mount) delete(pattern string, handler Handler) {
	m.r.delete(join_mount(m.prefix, pattern), m.wrap(handler))
}

pub fn (mut m Mount) patch(pattern string, handler Handler) {
	m.r.patch(join_mount(m.prefix, pattern), m.wrap(handler))
}

pub fn (mut m Mount) options(pattern string, handler Handler) {
	m.r.options(join_mount(m.prefix, pattern), m.wrap(handler))
}

pub fn (mut m Mount) head(pattern string, handler Handler) {
	m.r.head(join_mount(m.prefix, pattern), m.wrap(handler))
}

pub fn (mut m Mount) route(method string, pattern string, handler Handler) {
	m.r.add(method, join_mount(m.prefix, pattern), m.wrap(handler))
}

fn (m &Mount) wrap(handler Handler) Handler {
	if m.mws.len == 0 {
		return handler
	}
	return chain(m.mws, handler)
}

fn join_mount(prefix string, pattern string) string {
	if prefix.len == 0 || prefix == '/' {
		return pattern
	}
	p := if pattern.starts_with('/') { pattern } else { '/' + pattern }
	return prefix.trim_right('/') + p
}

pub fn (mut app App) listen(addr string) ! {
	r := app.router
	mws := app.middlewares.clone()
	app_ctx := app.ctx
	opts := app.opts
	upgrades_in := app.upgrades.clone()

	inner := fn [r] (req http.Request) http.Response {
		return r.handle(req)
	}

	mut handler := Handler(inner)
	for i := mws.len - 1; i >= 0; i-- {
		mw := mws[i]
		prev := handler
		handler = mw(prev)
	}

	engine_handler := fn [handler, app_ctx] (req http.Request) http.Response {
		mut rq := req
		rq.ctx = app_ctx
		return handler(rq)
	}

	// Inject app ctx into upgrade requests (same contract as HTTP handlers).
	mut upgrades := []engine.UpgradeRoute{cap: upgrades_in.len}
	for u in upgrades_in {
		base := u.handler
		upgrades << engine.UpgradeRoute{
			method:  u.method
			pattern: u.pattern
			handler: fn [base, app_ctx] (mut c engine.Conn, req http.Request) {
				mut rq := req
				rq.ctx = app_ctx
				base(mut c, rq)
			}
		}
	}

	engine.listen_and_serve_full(addr, engine_handler, upgrades, opts)!
}

// switching_protocols is a convenience for upgrade handlers (101 + Upgrade header).
pub fn switching_protocols(upgrade_proto string) http.Response {
	return http.Response.switching_protocols(upgrade_proto)
}

// http_date formats a time as HTTP-date (IMF-fixdate, GMT). Prefer time.utc().
pub fn http_date(t time.Time) string {
	return http.http_date(t)
}

pub fn text(status int, body string) http.Response {
	return http.Response.text(status, body)
}

pub fn json(status int, body string) http.Response {
	return http.Response.json(status, body)
}

pub fn empty(status int) http.Response {
	return http.Response.empty(status)
}

pub fn not_found() http.Response {
	return http.Response.not_found()
}

pub fn logger(next Handler) Handler {
	return fn [next] (req http.Request) http.Response {
		start := time.now()
		resp := next(req)
		ms := time.since(start).milliseconds()
		eprintln('[viltrum] ${req.method} ${req.path} -> ${resp.status} ${ms}ms')
		return resp
	}
}

pub fn recover(next Handler) Handler {
	return fn [next] (req http.Request) http.Response {
		mut resp := next(req)
		if resp.status == 0 {
			resp = http.Response.text(500, 'internal error')
			resp.set_connection_close()
			return resp
		}
		if resp.headers.get_or('content-length', '') == '' {
			resp.headers.set('Content-Length', '${resp.body.len}')
		}
		return resp
	}
}

pub fn cors(allow_origin string) Middleware {
	origin := allow_origin
	return fn [origin] (next Handler) Handler {
		return fn [next, origin] (req http.Request) http.Response {
			if req.method == 'OPTIONS' {
				mut resp := http.Response.empty(204)
				resp.headers.set('Access-Control-Allow-Origin', origin)
				resp.headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
				resp.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization')
				resp.headers.set('Access-Control-Max-Age', '86400')
				return resp
			}
			mut resp := next(req)
			resp.headers.set('Access-Control-Allow-Origin', origin)
			return resp
		}
	}
}

pub fn static_files(url_prefix string, root string) Middleware {
	prefix := http.normalize_path(url_prefix)
	root_path := root
	return fn [prefix, root_path] (next Handler) Handler {
		return fn [next, prefix, root_path] (req http.Request) http.Response {
			if req.method != 'GET' && req.method != 'HEAD' {
				return next(req)
			}
			path := http.normalize_path(req.path)
			if prefix != '/' {
				if path != prefix && !path.starts_with(prefix + '/') {
					return next(req)
				}
			}
			rel := if prefix == '/' {
				path
			} else if path == prefix {
				'/'
			} else {
				path[prefix.len..]
			}
			if resp := staticf.file_response(root_path, rel) {
				if req.method == 'HEAD' {
					mut h := resp
					h.body = []u8{}
					return h
				}
				return resp
			}
			return next(req)
		}
	}
}

pub fn serve_file(root string, rel string) ?http.Response {
	return staticf.file_response(root, rel)
}
