module viltrum

import viltrum.engine
import viltrum.http1
import viltrum.router

// Viltrum is an HTTP/1.1 framework for V with its own engine: one epoll worker per
// CPU, and no allocation per request inside the framework.

pub const version = '1.0.2'

pub type Ctx = http1.Ctx
pub type Handler = fn (mut Ctx)

pub type Method = http1.Method
pub type Options = engine.Options

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
}

pub fn new() &App {
	return &App{}
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
	c.text(405, 'method not allowed')
}

// listen serves until SIGINT/SIGTERM (or Options.stop).
pub fn (app &App) listen(addr string) ! {
	r := app.build()!
	engine.serve(addr, r, app.opts)!
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
