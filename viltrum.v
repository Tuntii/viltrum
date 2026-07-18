module viltrum

// Viltrum — Axum-style HTTP facade for V with its own engine.
// Non-goals v0.1: HTTP/2, TLS, WebSocket, veb compatibility.

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
}

pub fn new() App {
	return App{
		router: router.Router.new()
	}
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

	inner := fn [r] (req http.Request) http.Response {
		return r.handle(req)
	}

	// Adapt Middleware [] to service chain via manual fold
	mut handler := Handler(inner)
	for i := mws.len - 1; i >= 0; i-- {
		mw := mws[i]
		prev := handler
		handler = mw(prev)
	}

	raw := fn [handler] (raw_req []u8) []u8 {
		req := http.parse_request(raw_req) or {
			return http.Response.bad_request(err.msg()).to_bytes()
		}
		resp := handler(req)
		return resp.to_bytes()
	}

	engine.listen_and_serve(addr, raw)!
}

pub fn text(status int, body string) http.Response {
	return http.Response.text(status, body)
}

pub fn json(status int, body string) http.Response {
	return http.Response.json(status, body)
}

pub fn param(req http.Request, name string) ?string {
	return router.param(req, name)
}

pub fn logger(next Handler) Handler {
	return fn [next] (req http.Request) http.Response {
		resp := next(req)
		eprintln('[viltrum] ${req.method} ${req.path} -> ${resp.status}')
		return resp
	}
}
