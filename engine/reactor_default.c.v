module engine

// Non-Linux stub: epoll reactor is Linux-only.

fn serve_epoll_cores(_addr string, _handler Handler, _upgrades []UpgradeRoute, _opts ServerOptions, _stats &ConnStats, _cores int) ! {
	return error('epoll requires Linux')
}
