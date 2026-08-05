module engine

// Experimental Linux epoll reactor (cleartext). One thread, many non-blocking
// sockets. Uses viltrum http parse/serialize; does not share Conn/upgrade path.
// Enable with ServerOptions.use_epoll. Measure before productizing.

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
	slots   []ReactorSlot
	fd_map  []int
	n_conns int
}

// serve_epoll runs a single-thread epoll loop until the process is signalled or
// the listener fails. Blocks the calling thread (like the normal accept loop).
fn serve_epoll(addr string, handler Handler, opts ServerOptions) ! {
	mut listener := net.listen_tcp(.ip, addr)!
	lfd := listener.sock.handle
	net.set_blocking(lfd, false)!

	epfd := C.epoll_create1(0)
	if epfd < 0 {
		return error('epoll_create1 failed')
	}
	defer {
		C.close(epfd)
		listener.close() or {}
	}

	mut lev := C.epoll_event{}
	lev.events = u32(C.EPOLLIN)
	lev.data.fd = lfd
	if C.epoll_ctl(epfd, C.EPOLL_CTL_ADD, lfd, &lev) != 0 {
		return error('epoll_ctl add listener failed')
	}

	mut st := ReactorState{
		slots:   []ReactorSlot{len: 256}
		fd_map:  []int{len: reactor_fd_cap, init: -1}
		n_conns: 0
	}
	max_conns := if opts.max_conns > 0 { opts.max_conns } else { 0 }

	shared stopping := SignalStop{}
	if opts.handle_signals {
		os.signal_opt(.int, fn [shared stopping, mut listener] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGINT)')
			listener.close() or {}
		}) or {}
		os.signal_opt(.term, fn [shared stopping, mut listener] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGTERM)')
			listener.close() or {}
		}) or {}
	}

	eprintln('[viltrum] listening on http://${addr} (epoll reactor)')

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
			eprintln('[viltrum] epoll_wait: errno ${C.errno}')
			break
		}
		for i in 0 .. n {
			fd := unsafe { events[i].data.fd }
			ev := unsafe { events[i].events }
			if fd == lfd {
				reactor_accept(epfd, lfd, mut st, max_conns) or {
					msg := err.msg().to_lower()
					if msg.contains('closed') || msg.contains('bad file') {
						return
					}
					continue
				}
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
	eprintln('[viltrum] stopped')
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
		if max_conns > 0 && st.n_conns >= max_conns {
			busy := 'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 19\r\n\r\nservice unavailable'
			C.send(cfd, busy.str, busy.len, C.MSG_NOSIGNAL)
			C.close(cfd)
			continue
		}
		if cfd >= reactor_fd_cap {
			C.close(cfd)
			continue
		}
		flag := 1
		C.setsockopt(cfd, C.IPPROTO_TCP, C.TCP_NODELAY, &flag, sizeof(int))
		net.set_blocking(cfd, false) or {
			C.close(cfd)
			continue
		}
		si := reactor_alloc_slot(mut st) or {
			C.close(cfd)
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
