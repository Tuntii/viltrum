module engine

import sync.stdatomic
import time
import viltrum.router

#include <sys/epoll.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <errno.h>

fn C.epoll_create1(flags int) int
fn C.epoll_ctl(epfd int, op int, fd int, event &C.epoll_event) int
fn C.epoll_wait(epfd int, events &C.epoll_event, maxevents int, timeout_ms int) int
fn C.accept4(sockfd int, addr voidptr, addrlen voidptr, flags int) int

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

const max_events = 512
const shrink_rbuf_above = 64 * 1024
const shrink_wbuf_above = 256 * 1024
const busy_msg = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\nConnection: close\r\n\r\nservice unavailable'

struct Loop {
mut:
	w          &Worker
	epfd       int
	lfds       []int        // one listening socket per Listener
	srvs       []&TlsServer // per Listener: this worker's TLS state, nil for cleartext
	conns      []&Conn      // open connections, indexed by fd
	free       []&Conn      // closed connections, kept with their buffers for the next accept
	opts       Options
	stop       &Stop
	count      &ConnCount
	now        i64 // ms (time.ticks)
	last_sweep i64
	paused     bool // listener removed from epoll after EMFILE/ENFILE
}

fn run_worker(index int, lfds []int, listeners []Listener, r &router.Router, opts Options, mut stop Stop, mut count ConnCount) {
	// cold: one Loop per worker, on the heap. A by-value Loop holding conns would be
	// pinned (walked, and past 32 conns locked) around every call in the event loop
	// by V's -prod Boehm codegen; see jsonenc.encode_into.
	mut l := &Loop{
		w:     new_worker(r, opts, index)
		epfd:  C.epoll_create1(0)
		lfds:  lfds
		opts:  opts
		stop:  stop
		count: count
	}
	mut ok := l.epfd >= 0
	for i, ln in listeners {
		if t := ln.tls {
			srv := new_tls_server(t, index == 0) or {
				eprintln('[viltrum] worker ${index}: ${err.msg()}') // cold: startup failure
				ok = false
				unsafe { &TlsServer(nil) }
			}
			l.srvs << srv
		} else {
			l.srvs << unsafe { &TlsServer(nil) }
		}
		ok = ok && l.ctl(C.EPOLL_CTL_ADD, lfds[i], u32(C.EPOLLIN))
	}
	if !ok {
		// serve returns an error once the workers stop
		eprintln('[viltrum] worker ${index}: epoll setup failed') // cold: startup failure
		stdatomic.add_i64(&count.failed, 1)
		stop.request()
		if l.epfd >= 0 {
			C.close(l.epfd)
		}
		return
	}
	l.run()
}

// run is the event loop; only the receiver pointer and scalars are in scope here.
fn (mut l Loop) run() {
	mut events := [max_events]C.epoll_event{}
	for !l.stop.requested() {
		n := C.epoll_wait(l.epfd, &events[0], max_events, l.wait_ms())
		l.now = time.ticks()
		for i in 0 .. n {
			fd := unsafe { events[i].data.fd }
			li := l.listener_index(fd)
			if li >= 0 {
				l.accept_all(li)
			} else {
				l.on_event(fd, events[i].events)
			}
		}
		l.fire()
		if l.now - l.last_sweep >= 1000 {
			l.sweep()
			l.last_sweep = l.now
		}
	}
	for i in 0 .. l.conns.len {
		if !isnil(l.conns[i]) && l.conns[i].fd >= 0 {
			mut c := l.conns[i]
			l.close(mut c)
		}
	}
	C.close(l.epfd)
}

// wait_ms is the epoll timeout: until the next deferred response is due, rounded up
// so none fires early, and at most a second so stop and sweep are noticed.
fn (l &Loop) wait_ms() int {
	if l.w.timers.a.len == 0 {
		return 1000
	}
	due := l.w.timers.due_at()
	now := time.sys_mono_now()
	if due <= now {
		return 0
	}
	ms := (due - now + 999_999) / 1_000_000
	return if ms > 1000 { 1000 } else { int(ms) }
}

// fire writes every deferred response that is due, then serves what was pipelined
// behind each. A timer whose connection has closed (or been reused) is dropped.
fn (mut l Loop) fire() {
	if l.w.timers.a.len == 0 {
		return
	}
	now := time.sys_mono_now()
	for l.w.timers.a.len > 0 && l.w.timers.due_at() <= now {
		t := l.w.timers.pop()
		if t.fd >= l.conns.len || isnil(l.conns[t.fd]) {
			continue
		}
		mut c := l.conns[t.fd]
		if c.fd != t.fd || c.gen != t.gen || !c.waiting {
			continue
		}
		l.w.resume(mut c)
		l.drain(mut c)
		l.read_pending(mut c)
		if c.fd >= 0 && !c.out_armed {
			c.deadline_ms = l.now + if c.reading {
				l.opts.read_timeout.milliseconds()
			} else {
				l.opts.idle_timeout.milliseconds()
			}
		}
	}
}

fn (mut l Loop) ctl(op int, fd int, events u32) bool {
	mut ev := C.epoll_event{}
	ev.events = events
	ev.data.fd = fd
	return C.epoll_ctl(l.epfd, op, fd, &ev) == 0
}

// listener_index is the Listener whose socket fd is, or -1 for a connection.
fn (l &Loop) listener_index(fd int) int {
	for i, lfd in l.lfds {
		if lfd == fd {
			return i
		}
	}
	return -1
}

fn (mut l Loop) accept_all(li int) {
	lfd := l.lfds[li]
	srv := l.srvs[li]
	for {
		fd := C.accept4(lfd, unsafe { nil }, unsafe { nil }, C.SOCK_NONBLOCK | C.SOCK_CLOEXEC)
		if fd < 0 {
			if C.errno == C.EMFILE || C.errno == C.ENFILE {
				// out of fds: the backlog keeps the listeners readable, so stop polling them until sweep
				for x in l.lfds {
					l.ctl(C.EPOLL_CTL_DEL, x, 0)
				}
				l.paused = true
			}
			// EAGAIN, or an error the next readiness event retries
			return
		}
		mut counted := false
		if l.opts.max_conns > 0 {
			if !l.count.try_add(l.opts.max_conns) {
				if isnil(srv) {
					// a TLS client could not read a plaintext 503
					C.send(fd, busy_msg.str, busy_msg.len, C.MSG_NOSIGNAL)
				}
				C.close(fd)
				continue
			}
			counted = true
		}
		one := 1
		C.setsockopt(fd, C.IPPROTO_TCP, C.TCP_NODELAY, &one, sizeof(int))
		mut c := l.conn_for(fd)
		c.reset(fd)
		// a Conn is not tied to one fd, so its generation comes from the worker
		l.w.gen++
		c.gen = l.w.gen
		c.counted = counted
		c.deadline_ms = l.now + l.opts.idle_timeout.milliseconds()
		if !isnil(srv) {
			// the handshake runs under the read timeout, like a partial request
			c.deadline_ms = l.now + l.opts.read_timeout.milliseconds()
			if !c.tls_start(srv) {
				l.conns[fd] = unsafe { nil }
				c.fd = -1
				if counted {
					l.count.release()
				}
				l.free << c // cold: setup failure
				C.close(fd)
				continue
			}
		}
		l.ctl(C.EPOLL_CTL_ADD, fd, u32(C.EPOLLIN) | u32(C.EPOLLRDHUP))
	}
}

fn (mut l Loop) conn_for(fd int) &Conn {
	for l.conns.len <= fd {
		l.conns << unsafe { &Conn(nil) } // cold: once per new highest fd
	}
	// fd numbers are shared by all workers, so a Conn is pooled per worker rather than
	// kept per fd: a worker holds as many as it ever had open at once.
	mut c := if l.free.len > 0 { l.free.pop() } else { new_conn() } // cold: new_conn only past the worker's peak
	l.conns[fd] = c
	return c
}

fn (mut l Loop) on_event(fd int, ev u32) {
	if fd >= l.conns.len || isnil(l.conns[fd]) || l.conns[fd].fd != fd {
		return
	}
	mut c := l.conns[fd]
	if ev & (u32(C.EPOLLERR) | u32(C.EPOLLHUP)) != 0 {
		l.close(mut c)
		return
	}
	if !isnil(c.tls) {
		c.tls.readable()
		if c.tls.handshaking {
			l.handshake(mut c)
			return
		}
	}
	if c.out_armed {
		if ev & u32(C.EPOLLOUT) != 0 {
			l.flush(mut c)
			if c.fd >= 0 && !c.out_armed {
				l.drain(mut c)
				l.read_pending(mut c)
			}
		}
		return
	}
	if ev & (u32(C.EPOLLIN) | u32(C.EPOLLRDHUP)) != 0 {
		l.on_readable(mut c)
	}
}

// handshake advances a TLS handshake. Once it is done the connection reads like
// any other; the client's first request may already be buffered.
fn (mut l Loop) handshake(mut c Conn) {
	r := c.tls.handshake()
	if r == hs_failed {
		l.close(mut c)
		return
	}
	if r == hs_want_write && !c.out_armed {
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLOUT))
		c.out_armed = true
	} else if r != hs_want_write && c.out_armed {
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLIN) | u32(C.EPOLLRDHUP))
		c.out_armed = false
	}
	if r == hs_done {
		c.deadline_ms = l.now + l.opts.idle_timeout.milliseconds()
		l.on_readable(mut c)
	}
}

// read_pending reads input a TLS session already holds: epoll reports only the
// socket, so once output stops blocking the connection nothing else would.
fn (mut l Loop) read_pending(mut c Conn) {
	if c.fd >= 0 && !c.out_armed && !isnil(c.tls) && c.tls.pending() {
		l.on_readable(mut c)
	}
}

// read is recv over the connection's transport: bytes read, 0 when the peer closed,
// -1 when nothing is available now, -2 on error.
fn (mut l Loop) read(mut c Conn, buf &u8, n int) int {
	if !isnil(c.tls) {
		return c.tls.read(buf, n)
	}
	r := int(C.recv(c.fd, buf, n, 0))
	if r >= 0 {
		return r
	}
	return if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK { -1 } else { -2 }
}

// write is send over the connection's transport: bytes taken, -1 when the socket is
// full, -2 on error.
fn (mut l Loop) write(mut c Conn, buf &u8, n int) int {
	if !isnil(c.tls) {
		return c.tls.write(buf, n)
	}
	r := int(C.send(c.fd, buf, n, C.MSG_NOSIGNAL))
	if r >= 0 {
		return r
	}
	return if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK { -1 } else { -2 }
}

fn (mut l Loop) on_readable(mut c Conn) {
	max_total := l.opts.limits.max_header_bytes + l.opts.limits.max_body_bytes + 64 * 1024
	for {
		if c.rbuf.len == c.rbuf.cap {
			if c.rbuf.cap >= max_total {
				l.close(mut c)
				return
			}
			unsafe { c.rbuf.grow_cap(c.rbuf.cap) } // cold: a request larger than the buffer
		}
		spare := c.rbuf.cap - c.rbuf.len
		n := l.read(mut c, unsafe { &u8(c.rbuf.data) + c.rbuf.len }, spare)
		if n == 0 || n == -2 {
			l.close(mut c)
			return
		}
		if n < 0 {
			return
		}
		unsafe {
			c.rbuf.len += n
		}
		was_reading := c.reading
		reqs_before := l.w.requests
		l.drain(mut c)
		if c.fd < 0 || c.out_armed {
			return
		}
		if c.reading && (!was_reading || l.w.requests != reqs_before) {
			c.deadline_ms = l.now + l.opts.read_timeout.milliseconds()
		} else if !c.reading {
			c.deadline_ms = l.now + l.opts.idle_timeout.milliseconds()
		}
		if n < spare && isnil(c.tls) {
			// short read: the socket is drained, epoll reports more. Not for TLS: a
			// read returns at most one record, so read until it would block.
			return
		}
	}
}

// drain serves buffered requests and flushes until nothing more can be done now.
fn (mut l Loop) drain(mut c Conn) {
	for {
		before := c.rbuf.len
		l.w.process(mut c)
		l.flush(mut c)
		if c.fd < 0 || c.out_armed || c.rbuf.len == before {
			return
		}
	}
}

fn (mut l Loop) flush(mut c Conn) {
	for c.woff < c.wbuf.len {
		n := l.write(mut c, unsafe { &u8(c.wbuf.data) + c.woff }, c.wbuf.len - c.woff)
		if n < 0 {
			if n == -1 {
				if !c.out_armed {
					l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLOUT))
					c.out_armed = true
				}
				c.deadline_ms = l.now + l.opts.write_timeout.milliseconds()
				return
			}
			l.close(mut c)
			return
		}
		c.woff += n
	}
	unsafe {
		c.wbuf.len = 0
	}
	c.woff = 0
	if c.close_after {
		l.close(mut c)
		return
	}
	if c.out_armed {
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLIN) | u32(C.EPOLLRDHUP))
		c.out_armed = false
		c.deadline_ms = l.now + if c.reading {
			l.opts.read_timeout.milliseconds()
		} else {
			l.opts.idle_timeout.milliseconds()
		}
	}
}

fn (mut l Loop) close(mut c Conn) {
	if c.fd < 0 {
		return
	}
	l.ctl(C.EPOLL_CTL_DEL, c.fd, 0)
	if !isnil(c.tls) {
		c.tls.close()
		c.tls = unsafe { nil }
	}
	C.close(c.fd)
	if c.counted {
		l.count.release()
		c.counted = false
	}
	l.conns[c.fd] = unsafe { nil }
	c.fd = -1
	if c.rbuf.cap > shrink_rbuf_above {
		c.rbuf = []u8{cap: read_buf_size} // cold: give back what one large request grew
	}
	if c.wbuf.cap > shrink_wbuf_above {
		c.wbuf = []u8{cap: write_buf_size} // cold
	}
	l.free << c // cold: grows only past the worker's peak
}

fn (mut l Loop) sweep() {
	if l.paused {
		// a failed re-add leaves paused set so the next sweep retries
		l.paused = false
		for x in l.lfds {
			if !l.ctl(C.EPOLL_CTL_ADD, x, u32(C.EPOLLIN)) && C.errno != C.EEXIST {
				l.paused = true
			}
		}
	}
	for mut srv in l.srvs {
		if !isnil(srv) {
			srv.reload()
		}
	}
	for i in 0 .. l.conns.len {
		// a waiting connection is answered by its timer, not timed out
		if isnil(l.conns[i]) || l.conns[i].fd < 0 || l.conns[i].waiting
			|| l.now <= l.conns[i].deadline_ms {
			continue
		}
		mut c := l.conns[i]
		l.close(mut c)
	}
}
