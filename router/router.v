module router

// Method + path router with :param segments.

import viltrum.http

pub type HandlerFn = fn (req http.Request) http.Response

struct Route {
	method  string
	pattern string
	parts   []string
	handler HandlerFn = unsafe { nil }
}

pub struct Router {
mut:
	routes []Route
}

pub fn Router.new() Router {
	return Router{}
}

pub fn (mut r Router) add(method string, pattern string, handler HandlerFn) {
	parts := pattern.trim_right('/').split('/').filter(it.len > 0)
	r.routes << Route{
		method:  method.to_upper()
		pattern: pattern
		parts:   parts
		handler: handler
	}
}

pub fn (mut r Router) get(pattern string, handler HandlerFn) {
	r.add('GET', pattern, handler)
}

pub fn (mut r Router) post(pattern string, handler HandlerFn) {
	r.add('POST', pattern, handler)
}

pub fn (mut r Router) put(pattern string, handler HandlerFn) {
	r.add('PUT', pattern, handler)
}

pub fn (mut r Router) delete(pattern string, handler HandlerFn) {
	r.add('DELETE', pattern, handler)
}

pub fn (r &Router) handle(req http.Request) http.Response {
	path_parts := req.path.trim_right('/').split('/').filter(it.len > 0)
	mut method_matched := false

	for route in r.routes {
		params, ok := match_parts(route.parts, path_parts)
		if !ok {
			continue
		}
		if route.method != req.method.to_upper() {
			method_matched = true
			continue
		}
		mut enriched := req
		enriched.params = params.clone()
		return route.handler(enriched)
	}

	if method_matched {
		return http.Response.method_not_allowed()
	}
	return http.Response.not_found()
}

fn match_parts(pattern []string, path []string) (map[string]string, bool) {
	if pattern.len != path.len {
		return map[string]string{}, false
	}
	mut params := map[string]string{}
	for i, p in pattern {
		if p.starts_with(':') {
			params[p[1..]] = path[i]
			continue
		}
		if p != path[i] {
			return map[string]string{}, false
		}
	}
	return params, true
}
