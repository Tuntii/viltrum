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
	lfd        int
	conns      []&Conn // open connections, indexed by fd
	free       []&Conn // closed connections, kept with their buffers for the next accept
	opts       Options
	stop       &Stop
	count      &ConnCount
	now        i64 // ms (time.ticks)
	last_sweep i64
	paused     bool // listener removed from epoll after EMFILE/ENFILE
}

fn run_worker(index int, lfd int, r &router.Router, opts Options, mut stop Stop, mut count ConnCount) {
	// cold: one Loop per worker, on the heap. A by-value Loop holding conns would be
	// pinned (walked, and past 32 conns locked) around every call in the event loop
	// by V's -prod Boehm codegen; see jsonenc.encode_into.
	mut l := &Loop{
		w:     new_worker(r, opts, index)
		epfd:  C.epoll_create1(0)
		lfd:   lfd
		opts:  opts
		stop:  stop
		count: count
	}
	if l.epfd < 0 || !l.ctl(C.EPOLL_CTL_ADD, lfd, u32(C.EPOLLIN)) {
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
		n := C.epoll_wait(l.epfd, &events[0], max_events, 1000)
		l.now = time.ticks()
		for i in 0 .. n {
			fd := unsafe { events[i].data.fd }
			if fd == l.lfd {
				l.accept_all()
			} else {
				l.on_event(fd, events[i].events)
			}
		}
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

fn (mut l Loop) ctl(op int, fd int, events u32) bool {
	mut ev := C.epoll_event{}
	ev.events = events
	ev.data.fd = fd
	return C.epoll_ctl(l.epfd, op, fd, &ev) == 0
}

fn (mut l Loop) accept_all() {
	for {
		fd := C.accept4(l.lfd, unsafe { nil }, unsafe { nil }, C.SOCK_NONBLOCK | C.SOCK_CLOEXEC)
		if fd < 0 {
			if C.errno == C.EMFILE || C.errno == C.ENFILE {
				// out of fds: the backlog keeps the listener readable, so stop polling it until sweep
				l.ctl(C.EPOLL_CTL_DEL, l.lfd, 0)
				l.paused = true
			}
			// EAGAIN, or an error the next readiness event retries
			return
		}
		mut counted := false
		if l.opts.max_conns > 0 {
			if !l.count.try_add(l.opts.max_conns) {
				C.send(fd, busy_msg.str, busy_msg.len, C.MSG_NOSIGNAL)
				C.close(fd)
				continue
			}
			counted = true
		}
		one := 1
		C.setsockopt(fd, C.IPPROTO_TCP, C.TCP_NODELAY, &one, sizeof(int))
		mut c := l.conn_for(fd)
		c.reset(fd)
		c.counted = counted
		c.deadline_ms = l.now + l.opts.idle_timeout.milliseconds()
		l.ctl(C.EPOLL_CTL_ADD, fd, u32(C.EPOLLIN | C.EPOLLRDHUP))
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
	if ev & u32(C.EPOLLERR | C.EPOLLHUP) != 0 {
		l.close(mut c)
		return
	}
	if c.out_armed {
		if ev & u32(C.EPOLLOUT) != 0 {
			l.flush(mut c)
			if c.fd >= 0 && !c.out_armed {
				l.drain(mut c)
			}
		}
		return
	}
	if ev & u32(C.EPOLLIN | C.EPOLLRDHUP) != 0 {
		l.on_readable(mut c)
	}
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
		n := int(C.recv(c.fd, unsafe { &u8(c.rbuf.data) + c.rbuf.len }, spare, 0))
		if n == 0 {
			l.close(mut c)
			return
		}
		if n < 0 {
			if C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
				l.close(mut c)
			}
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
		if n < spare {
			// short read: the socket is drained, epoll reports more
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
		n := int(C.send(c.fd, unsafe { &u8(c.wbuf.data) + c.woff }, c.wbuf.len - c.woff,
			C.MSG_NOSIGNAL))
		if n < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
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
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLIN | C.EPOLLRDHUP))
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
		l.paused = !l.ctl(C.EPOLL_CTL_ADD, l.lfd, u32(C.EPOLLIN))
	}
	for i in 0 .. l.conns.len {
		if isnil(l.conns[i]) || l.conns[i].fd < 0 || l.now <= l.conns[i].deadline_ms {
			continue
		}
		mut c := l.conns[i]
		l.close(mut c)
	}
}
