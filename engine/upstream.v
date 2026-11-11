module engine

import net
import time

// Upstreams are declared and resolved at startup (App.upstream); the client that
// reaches them is client.v.

// UpstreamOptions tunes an upstream (App.upstream). Counts are per worker.
pub struct UpstreamOptions {
pub:
	max_conns    int           = 64               // connections open to the upstream
	max_queue    int           = 1024             // fetches waiting for one; past it they answer .busy
	timeout      time.Duration = 10 * time.second // from the fetch to the whole reply
	idle_timeout time.Duration = 30 * time.second // a pooled connection unused this long closes
	max_reply    int           = 1024 * 1024      // head and body; past it the fetch answers .too_big
}

// UpstreamSpec is an upstream resolved at startup (new_upstream).
pub struct UpstreamSpec {
pub:
	host string // the Host header: host[:port] as the URL gave it
	addr net.Addr
	opts UpstreamOptions
}

// new_upstream resolves an `http://host[:port]` URL once, at startup: the event loop
// never waits on DNS.
pub fn new_upstream(url string, opts UpstreamOptions) !UpstreamSpec {
	if url.starts_with('https://') {
		return error('viltrum: TLS upstreams are not supported yet: ${url}')
	}
	if !url.starts_with('http://') {
		return error('viltrum: an upstream URL starts with http:// (${url})')
	}
	host := url[7..].trim_right('/')
	if host.len == 0 {
		return error('viltrum: an upstream URL names a host (${url})')
	}
	for b in host {
		if b <= 0x20 || b == 0x7f || b == `/` || b == `?` || b == `#` || b == `@` {
			return error('viltrum: an upstream URL is http://host[:port], no path (${url})')
		}
	}
	has_port := if host.starts_with('[') { host.contains(']:') } else { host.contains(':') }
	addrs := net.resolve_addrs(if has_port { host } else { host + ':80' }, .unspec, .tcp)!
	if addrs.len == 0 {
		return error('viltrum: ${host} did not resolve')
	}
	if opts.max_conns < 1 || opts.max_queue < 0 || opts.max_reply < 1 {
		return error('viltrum: upstream ${host}: max_conns and max_reply must be positive')
	}
	return UpstreamSpec{
		host: host
		addr: addrs[0]
		opts: opts
	}
}
