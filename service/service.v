module service

// Handler + middleware chain helpers.

import viltrum.http

pub type HandlerFn = fn (req http.Request) http.Response

pub type MiddlewareFn = fn (next HandlerFn) HandlerFn

// chain applies middlewares in registration order (first = outermost).
pub fn chain(handler HandlerFn, middlewares []MiddlewareFn) HandlerFn {
	mut h := handler
	for i := middlewares.len - 1; i >= 0; i-- {
		mw := middlewares[i]
		h = mw(h)
	}
	return h
}

pub fn logger(next HandlerFn) HandlerFn {
	return fn [next] (req http.Request) http.Response {
		resp := next(req)
		eprintln('[viltrum] ${req.method} ${req.path} -> ${resp.status}')
		return resp
	}
}
