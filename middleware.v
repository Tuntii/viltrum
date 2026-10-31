module viltrum

import time
import viltrum.http1

// recover answers 500 and closes the connection when the rest of the chain wrote
// no response and deferred none (see Ctx.after). It cannot catch panics (V exits the process on one): run under a supervisor.
pub fn recover(mut c Ctx) {
	c.next()
	if !c.responded && !c.deferred {
		c.close()
		c.text(500, 'internal error')
	}
}

// gzip compresses text and JSON bodies of 256 bytes or more for clients that accept
// gzip (q-values honored). Register it before the handlers it should cover.
pub fn gzip(mut c Ctx) {
	http1.gzip_middleware(mut c)
}

// cors allows cross-origin requests from origin and answers preflight requests
// (OPTIONS with Access-Control-Request-Method). Any other OPTIONS reaches the routes.
pub fn cors(origin string) Handler {
	return fn [origin] (mut c Ctx) {
		c.set_header('Access-Control-Allow-Origin', origin)
		if c.method() == .options {
			if _ := c.header('Access-Control-Request-Method') {
				c.set_header('Access-Control-Allow-Methods',
					'GET, POST, PUT, PATCH, DELETE, OPTIONS')
				c.set_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
				c.set_header('Access-Control-Max-Age', '86400')
				c.no_content(204)
				return
			}
		}
		c.next()
	}
}

// logger prints one line per request. It formats and writes per request, so it
// allocates: leave it out of benchmarks. A deferred response (Ctx.after) is logged
// as "after", before it is written.
pub fn logger(mut c Ctx) {
	sw := time.new_stopwatch()
	c.next()
	// the engine answers 500 for a chain that wrote nothing
	status := if c.deferred {
		'after'
	} else if c.responded {
		c.status.str()
	} else {
		'500'
	}
	println('${c.method_name()} ${c.path()} ${status} ${sw.elapsed().microseconds()}us')
}
