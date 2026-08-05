module engine

// Non-Linux stub: epoll reactor is Linux-only.

fn serve_epoll(_addr string, _handler Handler, _opts ServerOptions) ! {
	return error('use_epoll requires Linux')
}
