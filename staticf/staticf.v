module staticf

// Static file serving helpers.

import os
import viltrum.http

pub fn file_response(root string, url_path string) ?http.Response {
	rel := sanitize_rel(url_path) or { return none }
	full := os.join_path(root, ...rel.split('/').filter(it.len > 0))
	if !os.exists(full) || !os.is_file(full) {
		return none
	}
	// path traversal guard: resolved path must stay under root
	abs_root := os.abs_path(root)
	abs_full := os.abs_path(full)
	root_pref := if abs_root.ends_with(os.path_separator) {
		abs_root
	} else {
		abs_root + os.path_separator
	}
	if abs_full != abs_root && !abs_full.starts_with(root_pref) {
		return none
	}
	data := os.read_bytes(full) or { return none }
	mut resp := http.Response{
		status:  200
		reason:  'OK'
		headers: http.HeaderMap.new()
		body:    data
	}
	resp.headers.set('Content-Type', content_type(full))
	resp.headers.set('Content-Length', '${resp.body.len}')
	resp.headers.set('Connection', 'keep-alive')
	return resp
}

fn sanitize_rel(url_path string) ?string {
	mut p := url_path.trim_space()
	if p.contains('\x00') || p.contains('..') {
		return none
	}
	p = p.trim_left('/')
	if p.len == 0 {
		return 'index.html'
	}
	return p
}

fn content_type(path string) string {
	lower := path.to_lower()
	return if lower.ends_with('.html') || lower.ends_with('.htm') {
		'text/html; charset=utf-8'
	} else if lower.ends_with('.css') {
		'text/css; charset=utf-8'
	} else if lower.ends_with('.js') {
		'application/javascript; charset=utf-8'
	} else if lower.ends_with('.json') {
		'application/json; charset=utf-8'
	} else if lower.ends_with('.svg') {
		'image/svg+xml'
	} else if lower.ends_with('.png') {
		'image/png'
	} else if lower.ends_with('.jpg') || lower.ends_with('.jpeg') {
		'image/jpeg'
	} else if lower.ends_with('.gif') {
		'image/gif'
	} else if lower.ends_with('.txt') || lower.ends_with('.md') {
		'text/plain; charset=utf-8'
	} else if lower.ends_with('.wasm') {
		'application/wasm'
	} else {
		'application/octet-stream'
	}
}
