module engine

// Upgrade / hijack routing. One clear path for leaving HTTP request/response.

import viltrum.http

// UpgradeFn receives full ownership of the connection for the rest of its life.
// The HTTP keep-alive loop does not resume after this returns.
//
// Contract:
//   - `req` is fully parsed (headers + Content-Length body if any).
//   - Any bytes already read past that message are in `c`'s pushback buffer
//     (see Conn.read). There is no separate leftover argument on purpose:
//     one ownership path, no double-delivery.
//   - The handler must write the protocol response (usually 101) itself.
//   - The handler should call c.close() when done; if it returns without closing,
//     the engine closes the conn.
//   - Global App middleware does not run for upgrade routes (by design, v0.4).
pub type UpgradeFn = fn (mut c Conn, req http.Request)

pub struct UpgradeRoute {
pub:
	method  string
	pattern string
	handler UpgradeFn = unsafe { nil }
}

struct UpgradeHit {
	handler UpgradeFn = unsafe { nil }
	params  map[string]string
}

// match_upgrade finds the first route matching method + path pattern.
// Patterns use the same :param and trailing *wildcard rules as the HTTP router.
fn match_upgrade(routes []UpgradeRoute, req http.Request) ?UpgradeHit {
	if routes.len == 0 {
		return none
	}
	method := req.method.to_upper()
	path := if req.path == '*' { '*' } else { http.normalize_path(req.path) }
	path_parts := if path == '*' {
		['*']
	} else {
		path.trim_right('/').split('/').filter(it.len > 0)
	}
	for route in routes {
		if route.method.to_upper() != method {
			continue
		}
		pat := normalize_upgrade_pattern(route.pattern)
		parts := pat.trim_right('/').split('/').filter(it.len > 0)
		params, ok := match_parts(parts, path_parts)
		if !ok {
			continue
		}
		return UpgradeHit{
			handler: route.handler
			params:  params
		}
	}
	return none
}

fn normalize_upgrade_pattern(pattern string) string {
	if pattern.len == 0 {
		return '/'
	}
	mut p := pattern
	if !p.starts_with('/') {
		p = '/' + p
	}
	if p.len > 1 && p.ends_with('/') {
		p = p.trim_right('/')
	}
	return p
}

// match_parts mirrors router rules: :id and trailing *rest.
fn match_parts(pattern []string, path []string) (map[string]string, bool) {
	mut params := map[string]string{}
	mut i := 0
	for pi, p in pattern {
		if p.starts_with('*') {
			if pi != pattern.len - 1 {
				return map[string]string{}, false
			}
			name := p[1..]
			if name.len == 0 {
				return map[string]string{}, false
			}
			rest := if i < path.len { path[i..].join('/') } else { '' }
			params[name] = rest
			return params, true
		}
		if i >= path.len {
			return map[string]string{}, false
		}
		if p.starts_with(':') {
			params[p[1..]] = path[i]
		} else if p != path[i] {
			return map[string]string{}, false
		}
		i++
	}
	return params, i == path.len
}
