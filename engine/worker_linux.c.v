module engine

import sync.stdatomic
import time
import viltrum.http1
import viltrum.router

#include <sys/epoll.h>
#include <sys/sendfile.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <errno.h>
#include "@VMODROOT/engine/wait_linux.h"

fn C.epoll_create1(flags int) int
fn C.epoll_ctl(epfd int, op int, fd int, event &C.epoll_event) int
fn C.viltrum_epoll_wait(epfd int, events &C.epoll_event, maxevents int, timeout_ns i64) int
fn C.accept4(sockfd int, addr voidptr, addrlen voidptr, flags int) int
fn C.sendfile(out_fd int, in_fd int, offset &i64, count usize) isize

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
const max_wait_ns = i64(1_000_000_000)
const sendfile_max = i64(1024 * 1024 * 1024) // per call; Linux moves at most ~2 GiB in one
const linger_idle_ms = 5000 // a lingering client quiet this long is closed
const linger_max_ms = 30000 // and any lingering client after this long
const busy_msg = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\nConnection: close\r\n\r\nservice unavailable'

struct Loop {
mut:
	w          &Worker
	epfd       int
	lfds       []int        // one listening socket per Listener
	srvs       []&TlsServer // per Listener: this worker's TLS state, nil for cleartext
	h2c        []bool       // per Listener: HTTP/2 with prior knowledge beside HTTP/1.1
	conns      []&Conn      // open connections, indexed by fd
	free       []&Conn      // closed connections, kept with their buffers for the next accept
	opts       Options
	stop       &Stop
	count      &ConnCount
	now        i64 // ms (time.ticks)
	last_sweep i64
	paused     bool // listener removed from epoll after EMFILE/ENFILE
	inbox      &Inbox = unsafe { nil }
	posts      []&http1.WsPost // the inbox's last batch
	touched    []&Conn         // connections a batch wrote to, to flush
	hs         []int           // fds whose first handshake step waits, oldest first from hs_head
	hs_head    int
}

fn run_worker(index int, lfds []int, listeners []Listener, r &router.Router, opts Options, hub &Hub, mut stop Stop, mut count ConnCount) {
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
		inbox: hub.boxes[index]
	}
	l.w.hub = hub
	mut ok := l.epfd >= 0 && l.ctl(C.EPOLL_CTL_ADD, l.inbox.efd, u32(C.EPOLLIN))
	for i, ln in listeners {
		mut h2c := ln.http2
		if t := ln.tls {
			h2c = false // over TLS, HTTP/2 is chosen by ALPN
			_ = t
		}
		l.h2c << h2c
		if t := ln.tls {
			srv := new_tls_server(t, index == 0, ln.http2) or {
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
		// with handshakes queued, only look for what is ready and run the next one
		wait := if l.hs_head < l.hs.len { i64(0) } else { l.wait_ns() }
		n := C.viltrum_epoll_wait(l.epfd, &events[0], max_events, wait)
		l.now = time.ticks()
		for i in 0 .. n {
			fd := unsafe { events[i].data.fd }
			if fd == l.inbox.efd {
				l.drain_inbox()
				continue
			}
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
		l.next_handshake()
	}
	for i in 0 .. l.conns.len {
		if !isnil(l.conns[i]) && l.conns[i].fd >= 0 {
			mut c := l.conns[i]
			l.close(mut c)
		}
	}
	C.close(l.epfd)
}

// wait_ns is the epoll timeout: until the next deferred response is due, and at most
// a second so stop and sweep are noticed.
fn (l &Loop) wait_ns() i64 {
	if l.w.timers.a.len == 0 {
		return max_wait_ns
	}
	due := l.w.timers.due_at()
	now := time.sys_mono_now()
	if due <= now {
		return 0
	}
	return if due - now > max_wait_ns { max_wait_ns } else { i64(due - now) }
}

// fire writes every deferred response that is due, then serves what was pipelined
// behind each. A timer whose connection has closed (or been reused), or whose HTTP/2
// stream was reset, is dropped.
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
		if c.fd != t.fd || c.gen != t.gen {
			continue
		}
		if t.tick != 0 {
			if !l.w.st_tick(mut c, t.stream, t.cb(), t.arg) {
				continue
			}
		} else if t.stream != 0 {
			if isnil(c.h2) || !l.w.h2_resume(mut c, t.stream) {
				continue
			}
		} else if c.waiting {
			l.w.resume(mut c)
		} else {
			continue
		}
		l.drain(mut c)
		l.read_pending(mut c)
		if c.fd >= 0 && !c.out_armed && !c.lingering && !l.h2_held_deadline(mut c) {
			c.deadline_ms = l.now + if c.reading {
				l.opts.read_timeout.milliseconds()
			} else {
				l.opts.idle_timeout.milliseconds()
			}
		}
	}
}

// drain_inbox writes the WebSocket messages other threads (and this worker's own
// callbacks) posted, then flushes every connection that got one.
fn (mut l Loop) drain_inbox() {
	mut n := u64(0)
	C.read(l.inbox.efd, &n, 8)
	l.inbox.take(mut l.posts)
	for i in 0 .. l.posts.len {
		l.w.deliver(l.posts[i], mut l.conns, mut l.touched)
		l.posts[i] = unsafe { nil } // let the message go
	}
	l.posts.clear()
	for i in 0 .. l.touched.len {
		mut c := l.touched[i]
		l.touched[i] = unsafe { nil }
		c.touched = false
		if c.fd >= 0 && !c.out_armed {
			l.flush(mut c)
		}
	}
	l.touched.clear()
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
		c.h2_ok = l.h2c[li]
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
		if !l.ctl(C.EPOLL_CTL_ADD, fd, u32(C.EPOLLIN) | u32(C.EPOLLRDHUP)) {
			// ENOMEM or ENOSPC (max_user_watches): never readable, so close it now
			// rather than hold it, and its max_conns slot, until the idle timeout
			l.close(mut c) // cold: setup failure
		}
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
	if c.lingering {
		l.discard(mut c)
		return
	}
	if !isnil(c.tls) {
		c.tls.readable()
		if c.tls.handshaking {
			if c.tls.fresh() {
				l.queue_handshake(mut c)
			} else {
				l.handshake(mut c)
			}
			return
		}
	}
	if c.out_armed {
		if ev & u32(C.EPOLLOUT) != 0 {
			l.flush(mut c)
			if c.fd >= 0 && !c.out_armed && !c.lingering {
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

// queue_handshake defers c's first handshake step to next_handshake.
fn (mut l Loop) queue_handshake(mut c Conn) {
	if !c.hs_queued {
		c.hs_queued = true
		l.hs << c.fd // cold: grows to the most handshakes ever waiting at once
	}
}

// next_handshake runs the oldest queued first handshake step. That step signs with
// the certificate's key: milliseconds of CPU with RSA, where a request takes
// microseconds. Run as they came, a burst of new connections held every open
// connection on the worker behind all of their handshakes (tens of milliseconds
// when a client opens hundreds at once); one per turn of the loop, with what is
// ready served in between, holds them behind one at most.
fn (mut l Loop) next_handshake() {
	for l.hs_head < l.hs.len {
		fd := l.hs[l.hs_head]
		l.hs_head++
		// the fd may have closed, or been reused by a connection queued again later
		if fd < l.conns.len && !isnil(l.conns[fd]) && l.conns[fd].fd == fd && l.conns[fd].hs_queued {
			mut c := l.conns[fd]
			c.hs_queued = false
			l.handshake(mut c)
			break
		}
	}
	if l.hs_head == l.hs.len && l.hs_head > 0 {
		l.hs.clear()
		l.hs_head = 0
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
		if c.tls.h2 {
			// ALPN chose h2: our SETTINGS go out now, the client's preface comes next
			l.w.h2_open(mut c)
		}
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
	for {
		r := int(C.recv(c.fd, buf, n, 0))
		if r >= 0 {
			return r
		}
		if C.errno != C.EINTR {
			break
		}
	}
	return if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK { -1 } else { -2 }
}

// write is send over the connection's transport: bytes taken, -1 when the socket is
// full, -2 on error.
fn (mut l Loop) write(mut c Conn, buf &u8, n int) int {
	if !isnil(c.tls) {
		return c.tls.write(buf, n)
	}
	for {
		r := int(C.send(c.fd, buf, n, C.MSG_NOSIGNAL))
		if r >= 0 {
			return r
		}
		if C.errno != C.EINTR {
			break
		}
	}
	return if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK { -1 } else { -2 }
}

fn (mut l Loop) on_readable(mut c Conn) {
	for {
		max_total := if isnil(c.ws) {
			l.opts.limits.max_header_bytes + l.opts.limits.max_body_bytes + 64 * 1024
		} else {
			c.ws.max_message + 64 * 1024
		}
		if c.rbuf.len == c.rbuf.cap {
			if c.rbuf.cap >= max_total {
				if !isnil(c.ws) || c.waiting || !isnil(c.st) || !isnil(c.h2) {
					// input piling up behind a WebSocket message, a deferred response, a
					// stream, or HTTP/2 frames not taken (they are at most 16 KiB, so never
					// one request)
					l.close(mut c)
					return
				}
				// one request larger than the limits, which framing has not refused yet:
				// a chunked body whose size lines push it past them
				l.w.refuse(mut c, http1.HttpError{
					status: 413
					reason: 'payload too large'
				})
				unsafe {
					c.rbuf.len = 0
				}
				c.reading = false
				l.flush(mut c)
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
		if c.fd < 0 || c.out_armed || c.lingering {
			return
		}
		if l.h2_held_deadline(mut c) {
		} else if !isnil(c.ws) {
			c.deadline_ms = l.ws_deadline(c)
		} else if c.reading && (!was_reading || l.w.requests != reqs_before) {
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
		if c.fd < 0 || c.out_armed || c.lingering || c.rbuf.len == before {
			return
		}
	}
}

fn (mut l Loop) flush(mut c Conn) {
	mut drained := 0 // what on_drain wrote in this flush
	mut ended := false // and whether it ended its stream
	for {
		for c.woff < c.wbuf.len {
			n := l.write(mut c, unsafe { &u8(c.wbuf.data) + c.woff }, c.wbuf.len - c.woff)
			if n < 0 {
				if n == -1 {
					l.arm_out(mut c)
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
		if c.file_fd >= 0 {
			if !l.send_file(mut c) {
				return
			}
			continue
		}
		// HTTP/2 output that flow control held back goes out as the socket takes it
		if !isnil(c.h2) && l.w.h2_pump(mut c) {
			continue
		}
		// a stream whose output is all out writes more, if it generates its body
		if isnil(c.st) {
			break
		}
		if drained >= stream_drain_max {
			// a client that takes everything at once does not hold the worker: the rest
			// waits for the next turn of the loop, which EPOLLOUT gives at once
			l.arm_out(mut c)
			return
		}
		if !l.w.st_drain(mut c) {
			break
		}
		drained += c.wbuf.len
		ended = isnil(c.st)
	}
	if c.close_after {
		if c.linger {
			l.linger(mut c)
		} else {
			l.close(mut c)
		}
		return
	}
	if c.out_armed {
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLIN) | u32(C.EPOLLRDHUP))
		c.out_armed = false
		if !l.h2_held_deadline(mut c) {
			c.deadline_ms = if !isnil(c.ws) {
				l.ws_deadline(c)
			} else if c.reading {
				l.now + l.opts.read_timeout.milliseconds()
			} else {
				l.now + l.opts.idle_timeout.milliseconds()
			}
		}
	}
	if ended && c.rbuf.len > 0 {
		l.drain(mut c) // the stream ended: requests the client pipelined behind it are next
	}
}

// h2_held_deadline gives an HTTP/2 connection whose output waits on the client's
// windows the write timeout, counted from when that output last moved: frames that
// move none of it (PING, unknown types) do not put it off. False when nothing waits.
fn (mut l Loop) h2_held_deadline(mut c Conn) bool {
	if isnil(c.h2) || c.h2.sending == 0 {
		return false
	}
	mut h := c.h2
	if h.sent != h.sent_seen {
		h.sent_seen = h.sent
		h.progress = l.now
	}
	c.deadline_ms = h.progress + l.opts.write_timeout.milliseconds()
	return true
}

// arm_out waits for the socket to take more output; reading pauses meanwhile.
fn (mut l Loop) arm_out(mut c Conn) {
	if !c.out_armed {
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLOUT))
		c.out_armed = true
	}
	c.deadline_ms = l.now + l.opts.write_timeout.milliseconds()
}

// send_file moves the streamed file on once wbuf is out: on cleartext straight from
// the page cache to the socket (sendfile), over TLS one buffer at a time through
// wbuf, which flush then writes. False when the socket is full (EPOLLOUT armed) or
// the connection was closed; true when there is more for flush to do or it is done.
fn (mut l Loop) send_file(mut c Conn) bool {
	if !isnil(c.tls) {
		n := if c.file_left < c.wbuf.cap { c.file_left } else { i64(c.wbuf.cap) }
		got := http1.read_at(c.file_fd, c.wbuf.data, n, c.file_off)
		if got <= 0 {
			l.close(mut c) // the file shrank: the promised Content-Length cannot be kept
			return false
		}
		unsafe {
			c.wbuf.len = int(got)
		}
		c.file_off += got
		c.file_left -= got
		if c.file_left == 0 {
			c.end_file()
		}
		return true
	}
	for c.file_left > 0 {
		chunk := if c.file_left < sendfile_max { c.file_left } else { sendfile_max }
		r := C.sendfile(c.fd, c.file_fd, &c.file_off, usize(chunk)) // advances file_off
		if r > 0 {
			c.file_left -= r
			continue
		}
		if r < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			l.arm_out(mut c)
			return false
		}
		if r < 0 && C.errno == C.EINTR {
			continue
		}
		l.close(mut c) // an error, or the file shrank (0)
		return false
	}
	c.end_file()
	return true
}

// linger closes a connection whose client may still be sending: the rest of a
// refused request, or requests pipelined behind a close. Closing with input unread
// makes the kernel answer with RST, and a client still writing its body may then
// lose the response before reading it. So the write side is shut (FIN after the
// response) and input is read and dropped until the client closes, stays quiet for
// linger_idle_ms, or linger_max_ms pass, as nginx's lingering close does.
fn (mut l Loop) linger(mut c Conn) {
	if !isnil(c.tls) {
		c.tls.close() // close_notify; what the client sends next is not decrypted
		c.tls = unsafe { nil }
	}
	if c.out_armed {
		l.ctl(C.EPOLL_CTL_MOD, c.fd, u32(C.EPOLLIN) | u32(C.EPOLLRDHUP))
		c.out_armed = false
	}
	C.shutdown(c.fd, C.SHUT_WR)
	c.lingering = true
	c.reading = false
	c.linger_end = l.now + linger_max_ms
	c.deadline_ms = l.now + linger_idle_ms
	l.discard(mut c)
}

// discard reads and drops a lingering connection's input; it closes the connection
// once the client has closed its side. A few reads per event, so a client that keeps
// sending cannot hold the worker.
fn (mut l Loop) discard(mut c Conn) {
	for _ in 0 .. 16 {
		n := int(C.recv(c.fd, c.rbuf.data, c.rbuf.cap, 0))
		if n > 0 {
			idle := l.now + linger_idle_ms
			c.deadline_ms = if idle < c.linger_end { idle } else { c.linger_end }
			continue
		}
		if n < 0 && C.errno == C.EINTR {
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			return
		}
		l.close(mut c)
		return
	}
}

// ws_deadline is when a quiet WebSocket connection times out: the handler's idle
// timeout (0: never), or the read timeout while our Close waits for the client's.
fn (l &Loop) ws_deadline(c &Conn) i64 {
	if c.ws_closing {
		return l.now + l.opts.read_timeout.milliseconds()
	}
	ms := c.ws.idle_timeout.milliseconds()
	return if ms > 0 { l.now + ms } else { max_i64 }
}

fn (mut l Loop) close(mut c Conn) {
	if c.fd < 0 {
		return
	}
	if !isnil(c.ws) {
		l.w.ws_end(mut c)
	}
	if !isnil(c.st) {
		l.w.st_end(mut c)
	}
	if !isnil(c.h2) {
		c.h2.close_streams()
		c.h2 = unsafe { nil }
	}
	c.end_file()
	c.hs_queued = false
	// the result does not matter: closing the fd, never dup'd, drops it from epoll too
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
	if c.ws_msg.cap > shrink_rbuf_above {
		c.ws_msg = []u8{} // cold: a large fragmented message
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
		if isnil(l.conns[i]) || l.conns[i].fd < 0 {
			continue
		}
		mut c := l.conns[i]
		if !isnil(c.st) && !c.out_armed {
			// a stream runs as long as its handler likes: the client is expected to stay
			// quiet. Only output that does not move times it out.
			if l.w.st_heartbeat(mut c, l.now) {
				l.flush(mut c)
			}
			continue
		}
		// a waiting connection is answered by its timer, not timed out
		if c.waiting || c.h2_waits() || l.now <= c.deadline_ms {
			continue
		}
		l.close(mut c)
	}
}
