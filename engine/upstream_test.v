module engine

// Literal addresses only: nothing here asks DNS.

fn test_new_upstream_accepts() {
	a := new_upstream('http://127.0.0.1:9', UpstreamOptions{})!
	assert a.host == '127.0.0.1:9'
	// no port: 80 is dialled, and Host stays as the URL gave it
	b := new_upstream('http://127.0.0.1/', UpstreamOptions{})!
	assert b.host == '127.0.0.1'
	c := new_upstream('http://127.0.0.1:9', UpstreamOptions{ max_queue: 0 })!
	assert c.opts.max_queue == 0
}

fn test_new_upstream_refuses() {
	for url in ['https://127.0.0.1', '127.0.0.1:80', 'ftp://127.0.0.1', 'http://', 'http:///',
		'http://127.0.0.1/api', 'http://127.0.0.1?x=1', 'http://127.0.0.1#f', 'http://u@127.0.0.1',
		'http://127.0.0.1 x'] {
		new_upstream(url, UpstreamOptions{}) or { continue }
		assert false, url
	}
	for o in [UpstreamOptions{
		max_conns: 0
	}, UpstreamOptions{
		max_queue: -1
	}, UpstreamOptions{
		max_reply: 0
	}] {
		new_upstream('http://127.0.0.1:9', o) or { continue }
		assert false, '${o}'
	}
}
