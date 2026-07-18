module viltrum

// Viltrum HTTP App facade. v0.3: shutdown, recover, timing logger.

import time
import viltrum.engine
import viltrum.http
import viltrum.router

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

// recover ensures a well-formed response even if the handler forgets headers.
// Full panic isolation is limited by the V runtime; this still hardens the happy path.
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
