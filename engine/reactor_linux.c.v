module engine

// Linux epoll reactor (cleartext). One nonblocking loop per core when
// epoll_cores > 1 (SO_REUSEPORT). HTTP parse/serialize stays viltrum's.
// Upgrade/WS is handed off a thread so the loop is not blocked.

import net
import os
import viltrum.http

#include <sys/epoll.h>
#include <errno.h>

fn C.epoll_create1(flags int) int
fn C.epoll_ctl(epfd int, op int, fd int, event &C.epoll_event) int
fn C.epoll_wait(epfd int, events &C.epoll_event, maxevents int, timeout_ms int) int

@[typedef]
union C.epoll_data_t {
mut:
	ptr voidptr
	fd  int
	u32 u32
	u64 u64
}

@[packed]
struct C.epoll_event {
mut:
	events u32
	data   C.epoll_data_t
}

const reactor_max_events = 256
const reactor_fd_cap = 8192
const reactor_read_chunk = 16 * 1024

struct ReactorSlot {
mut:
	used      bool
	fd        int
	assem     []u8
	write_buf []u8
	write_off int
	writing   bool
	close_me  bool // close after write drains
}

struct ReactorState {
mut:
	slots    []ReactorSlot
	fd_map   []int
	n_conns  int
	stats    &ConnStats = unsafe { nil }
	upgrades []UpgradeRoute
}

// serve_epoll_cores runs `cores` epoll loops. cores==1 is one listener.
// cores>1 is SO_REUSEPORT, one loop per listener. Blocks the caller.
fn serve_epoll_cores(addr string, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, stats &ConnStats, cores int) ! {
	n := if cores < 1 { 1 } else { cores }
	shared stopping := SignalStop{}
	mut set := &ListenerSet{}
	for _ in 0 .. n {
		set.items << listen_tcp_reuseport(addr)!
	}
	if opts.handle_signals {
		os.signal_opt(.int, fn [shared stopping, mut set] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGINT)')
			set.close_all()
		}) or {}
		os.signal_opt(.term, fn [shared stopping, mut set] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGTERM)')
			set.close_all()
		}) or {}
	}
	eprintln('[viltrum] listening on http://${addr} (epoll_cores=${n})')
	for i in 0 .. n - 1 {
		mut l := set.items[i]
		spawn reactor_run(mut l, handler, upgrades, opts, stats, shared stopping)
	}
	mut main_l := set.items[n - 1]
	reactor_run(mut main_l, handler, upgrades, opts, stats, shared stopping)
	set.close_all()
	unsafe {
		mut s := stats
		wait_drain(mut s, opts.drain_timeout)
	}
	eprintln('[viltrum] stopped')
}

fn reactor_run(mut listener net.TcpListener, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, stats &ConnStats, shared stopping SignalStop) {
	lfd := listener.sock.handle
	net.set_blocking(lfd, false) or { return }
	epfd := C.epoll_create1(0)
	if epfd < 0 {
		return
	}
	defer {
		C.close(epfd)
	}
	mut lev := C.epoll_event{}
	lev.events = u32(C.EPOLLIN)
	lev.data.fd = lfd
	if C.epoll_ctl(epfd, C.EPOLL_CTL_ADD, lfd, &lev) != 0 {
		return
	}
	mut st := ReactorState{
		slots:    []ReactorSlot{len: 256}
		fd_map:   []int{len: reactor_fd_cap, init: -1}
		n_conns:  0
		upgrades: upgrades
	}
	unsafe {
		st.stats = stats
	}
	max_conns := if opts.max_conns > 0 { opts.max_conns } else { 0 }
	mut events := [reactor_max_events]C.epoll_event{}
	mut tmp := []u8{len: reactor_read_chunk}
	for {
		if opts.handle_signals && signal_stop_get(shared stopping) {
			break
		}
		n := C.epoll_wait(epfd, &events[0], reactor_max_events, 500)
		if n < 0 {
			if C.errno == C.EINTR {
				continue
			}
			break
		}
		for i in 0 .. n {
			fd := unsafe { events[i].data.fd }
			ev := unsafe { events[i].events }
			if fd == lfd {
				reactor_accept(epfd, lfd, mut st, max_conns) or { continue }
				continue
			}
			if fd < 0 || fd >= reactor_fd_cap {
				continue
			}
			si := st.fd_map[fd]
			if si < 0 || si >= st.slots.len || !st.slots[si].used {
				continue
			}
			if ev & u32(C.EPOLLERR | C.EPOLLHUP) != 0 {
				reactor_close_slot(epfd, mut st, si)
				continue
			}
			if st.slots[si].writing || (ev & u32(C.EPOLLOUT)) != 0 {
				reactor_on_write(epfd, mut st, si)
			}
			if !st.slots[si].used {
				continue
			}
			if (ev & u32(C.EPOLLIN)) != 0 && !st.slots[si].writing {
				reactor_on_read(epfd, mut st, si, mut tmp, handler, opts)
			}
		}
	}
}

fn reactor_accept(epfd int, lfd int, mut st ReactorState, max_conns int) ! {
	for {
		cfd := C.accept(lfd, 0, 0)
		if cfd < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				return
			}
			return error('accept failed')
		}
		if st.stats != unsafe { nil } {
			mut acquired := false
			unsafe {
				mut s := st.stats
				acquired = s.try_acquire(max_conns)
			}
			if !acquired {
				busy := 'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 19\r\n\r\nservice unavailable'
				C.send(cfd, busy.str, busy.len, C.MSG_NOSIGNAL)
				C.close(cfd)
				continue
			}
		}
		if cfd >= reactor_fd_cap {
			C.close(cfd)
			st.release_conn()
			continue
		}
		flag := 1
		C.setsockopt(cfd, C.IPPROTO_TCP, C.TCP_NODELAY, &flag, sizeof(int))
		net.set_blocking(cfd, false) or {
			C.close(cfd)
			st.release_conn()
			continue
		}
		si := reactor_alloc_slot(mut st) or {
			C.close(cfd)
			st.release_conn()
			continue
		}
		st.slots[si].used = true
		st.slots[si].fd = cfd
		st.slots[si].assem = []u8{cap: 4096}
		st.slots[si].write_buf = []u8{}
		st.slots[si].write_off = 0
		st.slots[si].writing = false
		st.slots[si].close_me = false
		st.fd_map[cfd] = si
		st.n_conns++

		mut ev := C.epoll_event{}
		ev.events = u32(C.EPOLLIN)
		ev.data.fd = cfd
		if C.epoll_ctl(epfd, C.EPOLL_CTL_ADD, cfd, &ev) != 0 {
			reactor_close_slot(epfd, mut st, si)
			continue
		}
	}
}

fn reactor_alloc_slot(mut st ReactorState) ?int {
	for i in 0 .. st.slots.len {
		if !st.slots[i].used {
			return i
		}
	}
	if st.slots.len >= 8192 {
		return none
	}
	st.slots << ReactorSlot{}
	return st.slots.len - 1
}

fn reactor_close_slot(epfd int, mut st ReactorState, si int) {
	if si < 0 || si >= st.slots.len || !st.slots[si].used {
		return
	}
	fd := st.slots[si].fd
	mut ev := C.epoll_event{}
	C.epoll_ctl(epfd, C.EPOLL_CTL_DEL, fd, &ev)
	C.close(fd)
	st.release_conn()
	if fd >= 0 && fd < st.fd_map.len {
		st.fd_map[fd] = -1
	}
	st.slots[si].used = false
	st.slots[si].fd = -1
	st.slots[si].assem = []u8{}
	st.slots[si].write_buf = []u8{}
	st.slots[si].write_off = 0
	st.slots[si].writing = false
	st.slots[si].close_me = false
	if st.n_conns > 0 {
		st.n_conns--
	}
}

fn reactor_on_read(epfd int, mut st ReactorState, si int, mut tmp []u8, handler Handler, opts ServerOptions) {
	fd := st.slots[si].fd
	for {
		nr := unsafe { C.recv(fd, &tmp[0], tmp.len, 0) }
		if nr == 0 {
			reactor_close_slot(epfd, mut st, si)
			return
		}
		if nr < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				break
			}
			reactor_close_slot(epfd, mut st, si)
			return
		}
		st.slots[si].assem << tmp[..nr]
		if st.slots[si].assem.len > opts.max_header_bytes + opts.max_body_bytes {
			reactor_write_error(epfd, mut st, si, 413, 'payload too large')
			return
		}
		for {
			total := reactor_message_len(st.slots[si].assem) or { break }
			msg := st.slots[si].assem[..total].clone()
			if st.slots[si].assem.len > total {
				st.slots[si].assem = st.slots[si].assem[total..].clone()
			} else {
				unsafe {
					st.slots[si].assem.len = 0
				}
			}
			if !reactor_serve_one(epfd, mut st, si, msg, handler, opts) {
				return
			}
			if st.slots[si].writing {
				return
			}
		}
	}
}

fn reactor_message_len(buf []u8) ?int {
	hdr_end := index_of_double_crlf(buf) or { return none }
	body_start := hdr_end + 4
	hdr := unsafe { buf[..hdr_end] }
	if transfer_encoding_present(hdr) {
		return body_start
	}
	cl := content_length_from_headers(hdr) or { return body_start }
	if cl < 0 {
		return body_start
	}
	total := body_start + cl
	if buf.len < total {
		return none
	}
	return total
}

fn reactor_serve_one(epfd int, mut st ReactorState, si int, msg []u8, handler Handler, opts ServerOptions) bool {
	req := http.parse_request(msg) or {
		reactor_write_error(epfd, mut st, si, 400, err.msg())
		return st.slots[si].used
	}
	st.note_request()
	if hit := match_upgrade(st.upgrades, req) {
		reactor_handoff(epfd, mut st, si, req, hit, opts)
		return false
	}
	if opts.require_host && req.version.starts_with('HTTP/1.1') {
		if req.headers.get_or_lowered('host', '') == '' {
			reactor_write_error(epfd, mut st, si, 400, 'missing host header')
			return st.slots[si].used
		}
	}
	if req.body.len > opts.max_body_bytes {
		reactor_write_error(epfd, mut st, si, 413, 'payload too large')
		return st.slots[si].used
	}

	mut resp := handler(req)
	close_after := http.should_close(req, resp)
	if close_after {
		resp.headers.set_lowered('connection', 'close')
	} else if resp.headers.get_or_lowered('connection', '') == '' {
		resp.headers.set_lowered('connection', 'keep-alive')
	}
	apply_response_defaults(mut resp, opts)
	resp.to_bytes_for_method_into(mut st.slots[si].write_buf, req.method)
	st.slots[si].write_off = 0
	st.slots[si].writing = true
	st.slots[si].close_me = close_after
	reactor_on_write(epfd, mut st, si)
	return st.slots[si].used
}

fn reactor_write_error(epfd int, mut st ReactorState, si int, status int, msg string) {
	mut resp := http.Response.text(status, msg)
	resp.set_connection_close()
	resp.to_bytes_for_method_into(mut st.slots[si].write_buf, 'GET')
	st.slots[si].write_off = 0
	st.slots[si].writing = true
	st.slots[si].close_me = true
	reactor_on_write(epfd, mut st, si)
}

fn reactor_on_write(epfd int, mut st ReactorState, si int) {
	if !st.slots[si].used || !st.slots[si].writing {
		return
	}
	fd := st.slots[si].fd
	for st.slots[si].write_off < st.slots[si].write_buf.len {
		left := st.slots[si].write_buf.len - st.slots[si].write_off
		ptr := unsafe { &st.slots[si].write_buf[st.slots[si].write_off] }
		nw := unsafe { C.send(fd, ptr, left, C.MSG_NOSIGNAL) }
		if nw < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				mut ev := C.epoll_event{}
				ev.events = u32(C.EPOLLIN | C.EPOLLOUT)
				ev.data.fd = fd
				C.epoll_ctl(epfd, C.EPOLL_CTL_MOD, fd, &ev)
				return
			}
			reactor_close_slot(epfd, mut st, si)
			return
		}
		if nw == 0 {
			reactor_close_slot(epfd, mut st, si)
			return
		}
		st.slots[si].write_off += int(nw)
	}
	// write complete
	close_me := st.slots[si].close_me
	st.slots[si].writing = false
	st.slots[si].write_off = 0
	st.slots[si].close_me = false
	unsafe {
		st.slots[si].write_buf.len = 0
	}
	if close_me {
		reactor_close_slot(epfd, mut st, si)
		return
	}
	mut ev := C.epoll_event{}
	ev.events = u32(C.EPOLLIN)
	ev.data.fd = fd
	C.epoll_ctl(epfd, C.EPOLL_CTL_MOD, fd, &ev)
}

fn (mut st ReactorState) note_request() {
	if st.stats == unsafe { nil } {
		return
	}
	unsafe {
		mut s := st.stats
		s.add_request()
	}
}

fn (mut st ReactorState) release_conn() {
	if st.stats == unsafe { nil } {
		return
	}
	unsafe {
		mut s := st.stats
		s.release()
	}
}

// reactor_handoff detaches fd from the loop and runs the upgrade handler on
// its own thread. The slot is dropped without close; the handler owns the fd.
fn reactor_handoff(epfd int, mut st ReactorState, si int, req http.Request, hit UpgradeHit, opts ServerOptions) {
	if si < 0 || si >= st.slots.len || !st.slots[si].used {
		return
	}
	fd := st.slots[si].fd
	leftover := st.slots[si].assem.clone()
	mut ev := C.epoll_event{}
	C.epoll_ctl(epfd, C.EPOLL_CTL_DEL, fd, &ev)
	if fd >= 0 && fd < st.fd_map.len {
		st.fd_map[fd] = -1
	}
	st.slots[si].used = false
	st.slots[si].fd = -1
	st.slots[si].assem = []u8{}
	st.slots[si].write_buf = []u8{}
	st.slots[si].write_off = 0
	st.slots[si].writing = false
	st.slots[si].close_me = false
	if st.n_conns > 0 {
		st.n_conns--
	}
	net.set_blocking(fd, true) or {
		C.close(fd)
		st.release_conn()
		return
	}
	mut tcp := net.TcpConn{
		sock: net.TcpSocket{
			handle: fd
		}
		handle:         fd
		is_blocking:    true
		read_timeout:   upgrade_read_timeout(opts)
		write_timeout:  opts.write_timeout
	}
	c := Conn.wrap(mut tcp, leftover)
	mut rq := req
	rq.params = hit.params.clone()
	spawn run_handed_upgrade(c, hit.handler, rq, st.stats)
}

fn run_handed_upgrade(c_in Conn, handler UpgradeFn, req http.Request, stats &ConnStats) {
	mut c := c_in
	handler(mut c, req)
	if !c.is_closed() {
		c.close() or {}
	}
	if stats != unsafe { nil } {
		unsafe {
			mut s := stats
			s.release()
		}
	}
}
