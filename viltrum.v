module viltrum

// Viltrum — HTTP App facade. Engine + parse + router live in submodules.
// v0.2: keep-alive framing, params, optional app ctx.

import viltrum.engine
import viltrum.http
import viltrum.router

pub type Request = http.Request
pub type Response = http.Response
pub type Handler = fn (req http.Request) http.Response
pub type Middleware = fn (next Handler) Handler

pub struct App {
mut:
	router      router.Router
	middlewares []Middleware
	ctx         voidptr
}

pub fn new() App {
	return App{
		router: router.Router.new()
		ctx:    unsafe { nil }
	}
}

// set_ctx attaches a heap pointer available on every Request as req.ctx.
pub fn (mut app App) set_ctx(ptr voidptr) {
	app.ctx = ptr
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

pub fn (mut app App) use(mw Middleware) {
	app.middlewares << mw
}

pub fn (mut app App) listen(addr string) ! {
	r := app.router
	mws := app.middlewares.clone()
	app_ctx := app.ctx

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
		mut r := req
		r.ctx = app_ctx
		return handler(r)
	}

	engine.listen_and_serve(addr, engine_handler)!
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

// param reads a path :param (prefer req.param — kept for compatibility).
pub fn param(req http.Request, name string) ?string {
	return req.param(name)
}

pub fn logger(next Handler) Handler {
	return fn [next] (req http.Request) http.Response {
		resp := next(req)
		eprintln('[viltrum] ${req.method} ${req.path} -> ${resp.status}')
		return resp
	}
}
