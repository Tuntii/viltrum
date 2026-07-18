module viltrum

// Viltrum HTTP App facade.
// v0.3.2: wildcards, JSON field helpers, chain(), mount middleware.

import time
import viltrum.engine
import viltrum.http
import viltrum.router
import viltrum.staticf

pub type Request = http.Request
pub type Response = http.Response
pub type Handler = fn (req http.Request) http.Response
pub type Middleware = fn (next Handler) Handler
pub type ServerOptions = engine.ServerOptions

pub struct App {
mut:
	router      router.Router
	middlewares []Middleware
	ctx         voidptr
	opts        engine.ServerOptions
}

pub fn new() App {
	return App{
		router: router.Router.new()
		ctx:    unsafe { nil }
		opts:   engine.ServerOptions{}
	}
}

pub fn (mut app App) set_ctx(ptr voidptr) {
	app.ctx = ptr
}

pub fn (mut app App) options(opts engine.ServerOptions) {
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

pub fn (mut app App) route(method string, pattern string, handler Handler) {
	app.router.add(method, pattern, handler)
}

pub fn (mut app App) use(mw Middleware) {
	app.middlewares << mw
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

	engine.listen_and_serve_opt(addr, engine_handler, opts)!
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
