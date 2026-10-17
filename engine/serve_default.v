module engine

$if !linux {
	import runtime
	import viltrum.router

	// serve is a stub on non-Linux platforms. The epoll-based engine requires Linux.
	pub fn serve(addr string, r &router.Router, opts Options) ! {
		return error('viltrum: engine.serve is only supported on Linux (epoll)')
	}

	// worker_count resolves Options.workers or returns nr_cpus on non-Linux platforms.
	pub fn worker_count(requested int) int {
		if requested > 0 {
			return requested
		}
		return runtime.nr_cpus()
	}
}
