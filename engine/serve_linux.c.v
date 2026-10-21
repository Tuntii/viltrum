module engine

import net
import os
import runtime
import sync.stdatomic
import viltrum.router

#include <sched.h>

fn C.sched_getaffinity(pid int, size usize, mask voidptr) int

const listen_backlog = 4096

// ConnCount is the process-wide connection count behind max_conns.
@[heap]
struct ConnCount {
mut:
	active i64
	failed i64 // workers that could not start
}

// try_add takes a slot unless max are taken; approximate under races, which is
// fine for a soft limit.
fn (mut cc ConnCount) try_add(max int) bool {
	if stdatomic.add_i64(&cc.active, 1) > max {
		stdatomic.sub_i64(&cc.active, 1)
		return false
	}
	return true
}

fn (mut cc ConnCount) release() {
	stdatomic.sub_i64(&cc.active, 1)
}

// serve runs one epoll worker per CPU, each with its own SO_REUSEPORT listener, and
// blocks until SIGINT/SIGTERM or opts.stop asks it to stop.
pub fn serve(addr string, r &router.Router, opts Options) ! {
	serve_listeners([Listener{
		addr: addr
	}], r, opts)!
}

// serve_listeners is serve for several addresses at once, cleartext or TLS: every
// worker listens on all of them. Certificates are loaded before any socket opens,
// so a bad path fails here rather than in the workers.
pub fn serve_listeners(listeners []Listener, r &router.Router, opts Options) ! {
	if listeners.len == 0 {
		return error('viltrum: no listeners')
	}
	mut tls := false
	for ln in listeners {
		if t := ln.tls {
			if !tls {
				tls_init()!
				tls = true
			}
			mut probe := new_tls_server(t, false)!
			probe.free()
		}
	}
	n := worker_count(opts.workers)
	mut stop := if isnil(opts.stop) { new_stop() } else { opts.stop }
	mut lfds := [][]int{}
	for _ in 0 .. n {
		mut row := []int{}
		for ln in listeners {
			row << listen_reuseport(ln.addr) or {
				for fds in lfds {
					for fd in fds {
						C.close(fd)
					}
				}
				for fd in row {
					C.close(fd)
				}
				return err
			}
		}
		lfds << row
	}
	if opts.handle_signals {
		os.signal_opt(.int, fn [mut stop] (_ os.Signal) {
			stop.request()
		}) or {}
		os.signal_opt(.term, fn [mut stop] (_ os.Signal) {
			stop.request()
		}) or {}
	}
	for ln in listeners {
		scheme := if _ := ln.tls { 'https' } else { 'http' }
		eprintln('[viltrum] listening on ${scheme}://${ln.addr} (${n} workers)')
	}
	mut count := &ConnCount{}
	mut threads := []thread{}
	for i in 1 .. n {
		threads << spawn run_worker(i, lfds[i], listeners, r, opts, mut stop, mut count)
	}
	run_worker(0, lfds[0], listeners, r, opts, mut stop, mut count)
	threads.wait()
	for fds in lfds {
		for fd in fds {
			C.close(fd)
		}
	}
	if count.failed > 0 {
		return error('viltrum: ${count.failed} worker(s) failed to start epoll')
	}
}

// worker_count resolves Options.workers: an explicit count, else VILTRUM_WORKERS,
// else the CPUs in this process's affinity mask (taskset and cgroup cpusets count).
pub fn worker_count(requested int) int {
	if requested > 0 {
		return requested
	}
	if s := os.getenv_opt('VILTRUM_WORKERS') {
		n := s.int()
		if n > 0 {
			return n
		}
	}
	mut mask := [16]u64{}
	if C.sched_getaffinity(0, sizeof(mask), &mask[0]) == 0 {
		mut n := 0
		for w in mask {
			mut x := w
			for x != 0 {
				x &= x - 1
				n++
			}
		}
		if n > 0 {
			return n
		}
	}
	return runtime.nr_cpus()
}

fn listen_reuseport(addr string) !int {
	mut s := net.new_tcp_socket(.ip)!
	one := 1
	if C.setsockopt(s.handle, C.SOL_SOCKET, C.SO_REUSEPORT, &one, sizeof(int)) != 0 {
		return error('SO_REUSEPORT setsockopt failed')
	}
	s.bind(addr)!
	if C.listen(s.handle, listen_backlog) != 0 {
		return error('listen failed on ${addr}')
	}
	net.set_blocking(s.handle, false)!
	return s.handle
}
