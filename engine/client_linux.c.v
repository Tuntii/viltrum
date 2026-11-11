module engine

import viltrum.http1

// The HTTP client's sockets (client.v has the rest): peers sit in the worker's epoll
// set beside its connections, and a reply resumes the request that waits for it the
// way a timer resumes a deferred response.

const peer_in = u32(C.EPOLLIN) | u32(C.EPOLLRDHUP)
const peer_out = peer_in | u32(C.EPOLLOUT)
const peer_max_interims = 8 // 1xx replies one request may get
const peer_keep_wbuf = 64 * 1024 // a request buffer grown past this goes to the GC

// kick connects or writes the peers fetches took on this turn and answers the fetches
// that ended before reaching one. Answering runs callbacks, which can fetch again, so
// both lists are walked until they stay empty.
fn (mut l Loop) kick() {
	for l.w.fails.len > 0 || l.w.ready.len > 0 {
		for i := 0; i < l.w.fails.len; i++ {
			f := l.w.fails[i]
			l.w.reply_to(http1.Fetched{ err: f.err }, http1.view(l.w.ctx.buf, 0, 0))
			l.answer(f.waiter)
		}
		l.w.fails.clear()
		for i := 0; i < l.w.ready.len; i++ {
			mut peer := l.w.ready[i]
			l.w.ready[i] = unsafe { nil }
			if !peer.busy || peer.connecting {
				continue // answered meanwhile, or reconnecting: it sends once connected
			}
			if peer.fd >= 0 {
				l.peer_send(mut peer)
			} else {
				l.peer_connect(mut peer)
			}
		}
		l.w.ready.clear()
	}
}

// answer resumes the request or stream wt names, with the reply reply_to set. It is
// dropped when that request is gone: its client closed, or reset the stream.
fn (mut l Loop) answer(wt Waiter) {
	if wt.fd >= 0 && wt.fd < l.conns.len && !isnil(l.conns[wt.fd]) {
		mut c := l.conns[wt.fd]
		if c.fd == wt.fd && c.gen == wt.gen {
			l.w.lend(mut c)
			mut ok := false
			if wt.stream != 0 {
				ok = !isnil(c.h2) && l.w.h2_resume(mut c, wt.stream)
			} else if c.waiting && isnil(c.h2) {
				l.w.resume(mut c)
				ok = true
			}
			if ok {
				l.after_wait(mut c, wt.fd)
			} else {
				l.w.settle(mut c)
			}
		}
	}
	l.w.reply_done()
}

fn (mut l Loop) peer_connect(mut peer Peer) {
	addr := l.w.pools[peer.pool].spec.addr
	fd := int(C.socket(i32(addr.family()), i32(C.SOCK_STREAM | C.SOCK_NONBLOCK | C.SOCK_CLOEXEC), 0))
	if fd < 0 {
		l.peer_fail(mut peer, .connect)
		return
	}
	one := i32(1)
	C.setsockopt(fd, C.IPPROTO_TCP, C.TCP_NODELAY, &one, sizeof(i32))
	if C.connect(i32(fd), voidptr(&addr), addr.len()) != 0 && C.errno != C.EINPROGRESS {
		C.close(fd)
		l.peer_fail(mut peer, .connect)
		return
	}
	for l.peers.len <= fd {
		l.peers << unsafe { &Peer(nil) } // cold: once per new highest fd
	}
	l.peers[fd] = peer
	peer.fd = fd
	peer.connecting = true
	peer.out_armed = true
	if !l.ctl(C.EPOLL_CTL_ADD, fd, peer_out) {
		l.peer_fail(mut peer, .connect) // cold: epoll out of room
	}
}

fn (mut l Loop) on_peer(mut peer Peer, ev u32) {
	if peer.connecting {
		mut so_err := i32(0)
		mut n := u32(sizeof(i32))
		C.getsockopt(i32(peer.fd), C.SOL_SOCKET, C.SO_ERROR, &so_err, &n)
		if so_err != 0 || ev & (u32(C.EPOLLERR) | u32(C.EPOLLHUP)) != 0 {
			l.peer_fail(mut peer, .connect)
			return
		}
		if ev & u32(C.EPOLLOUT) == 0 {
			return
		}
		peer.connecting = false
		l.peer_send(mut peer)
		return
	}
	if !peer.busy {
		// an idle connection the upstream closed, or wrote to unasked
		l.peer_close(mut peer)
		return
	}
	if peer.out_armed && ev & u32(C.EPOLLOUT) != 0 {
		l.peer_send(mut peer)
		if peer.fd < 0 || !peer.busy {
			return
		}
	}
	if ev & (peer_in | u32(C.EPOLLHUP) | u32(C.EPOLLERR)) != 0 {
		l.peer_read(mut peer)
	}
}

// peer_send writes what is left of the request; the rest goes when the socket takes it.
fn (mut l Loop) peer_send(mut peer Peer) {
	for peer.woff < peer.wbuf.len {
		r := int(C.send(peer.fd, unsafe { &u8(peer.wbuf.data) + peer.woff },
			peer.wbuf.len - peer.woff, C.MSG_NOSIGNAL))
		if r >= 0 {
			peer.woff += r
			continue
		}
		if C.errno == C.EINTR {
			continue
		}
		if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
			if !peer.out_armed {
				peer.out_armed = true
				l.ctl(C.EPOLL_CTL_MOD, peer.fd, peer_out)
			}
			return
		}
		l.peer_lost(mut peer)
		return
	}
	if peer.out_armed {
		peer.out_armed = false
		l.ctl(C.EPOLL_CTL_MOD, peer.fd, peer_in)
	}
}

fn (mut l Loop) peer_read(mut peer Peer) {
	max := l.w.pools[peer.pool].spec.opts.max_reply
	mut eof := false
	for {
		if peer.rbuf.len == peer.rbuf.cap {
			if peer.rbuf.cap > max + 64 * 1024 {
				break // the framing below ends the fetch
			}
			unsafe { peer.rbuf.grow_cap(peer.rbuf.cap) } // cold: a reply larger than the buffer
		}
		spare := peer.rbuf.cap - peer.rbuf.len
		r := int(C.recv(peer.fd, unsafe { &u8(peer.rbuf.data) + peer.rbuf.len }, spare, 0))
		if r > 0 {
			unsafe {
				peer.rbuf.len += r
			}
			if r < spare {
				break
			}
			continue
		}
		if r < 0 && C.errno == C.EINTR {
			continue
		}
		if r < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			break
		}
		eof = true // closed, or reset
		break
	}
	if eof && peer.rbuf.len == 0 {
		l.peer_lost(mut peer)
		return
	}
	for {
		n := http1.frame_reply(peer.rbuf, mut peer.frame, peer.head, eof, max) or {
			l.peer_fail(mut peer, match err.code() {
				413 { http1.FetchError.too_big }
				503 { http1.FetchError.closed }
				else { http1.FetchError.protocol }
			})
			return
		}
		if n < 0 {
			// the read loop stopped at the cap: nothing more will be read, and the
			// socket would stay readable and wake the loop on every turn
			if peer.rbuf.len == peer.rbuf.cap && peer.rbuf.cap > max + 64 * 1024 {
				l.peer_fail(mut peer, .too_big)
			}
			return
		}
		if peer.frame.interim {
			peer.interims++
			if peer.interims > peer_max_interims {
				l.peer_fail(mut peer, .protocol)
				return
			}
			// a 1xx head: drop it, the reply follows
			rest := peer.rbuf.len - n
			unsafe {
				C.memmove(peer.rbuf.data, &u8(peer.rbuf.data) + n, rest)
				peer.rbuf.len = rest
			}
			peer.frame.reset()
			continue
		}
		body := http1.reply_body(peer.rbuf, &peer.frame, n)
		// a reply that overtook its request leaves unsent bytes the upstream still expects
		keep := peer.frame.keep && !eof && n == peer.rbuf.len && peer.woff == peer.wbuf.len
		wt := peer.waiter
		peer.busy = false
		peer.waiter = Waiter{}
		l.w.reply_to(http1.Fetched{
			err:    .none
			status: peer.frame.status
			body:   body
		}, http1.view(peer.rbuf, 0, peer.frame.head_end))
		l.answer(wt)
		l.peer_release(mut peer, keep)
		return
	}
}

// peer_lost handles a connection that broke before its reply began: a request that
// may be sent twice goes once more on a new connection (the upstream may have closed
// a pooled one just as it was taken), any other answers .closed.
fn (mut l Loop) peer_lost(mut peer Peer) {
	if peer.busy && peer.rbuf.len == 0 && peer.idem && !peer.retried {
		peer.retried = true
		l.peer_drop_fd(mut peer)
		peer.woff = 0
		peer.frame.reset()
		l.peer_connect(mut peer)
		return
	}
	l.peer_fail(mut peer, .closed)
}

// peer_fail answers the peer's fetch with err and closes the connection.
fn (mut l Loop) peer_fail(mut peer Peer, err http1.FetchError) {
	if peer.busy {
		wt := peer.waiter
		peer.busy = false
		peer.waiter = Waiter{}
		l.w.reply_to(http1.Fetched{ err: err }, http1.view(l.w.ctx.buf, 0, 0))
		l.answer(wt)
	}
	l.peer_close(mut peer)
}

// peer_release takes the next queued fetch on a connection whose reply is done, or
// keeps it idle; one that cannot carry another request closes.
fn (mut l Loop) peer_release(mut peer Peer, keep bool) {
	if !keep {
		l.peer_close(mut peer)
		return
	}
	peer.reset_bufs()
	mut p := &l.w.pools[peer.pool]
	if l.w.next_queued(mut p, mut peer) {
		l.peer_send(mut peer)
		return
	}
	peer.deadline_ms = l.now + p.spec.opts.idle_timeout.milliseconds()
	p.idle << peer // cold: grows to max_conns once
}

fn (mut peer Peer) reset_bufs() {
	if peer.rbuf.cap > shrink_rbuf_above {
		peer.rbuf = []u8{cap: read_buf_size} // cold: a large reply
	}
	if peer.wbuf.cap > peer_keep_wbuf {
		peer.wbuf = []u8{cap: 2048} // cold: a large request
	}
	unsafe {
		peer.rbuf.len = 0
		peer.wbuf.len = 0
	}
	peer.woff = 0
	peer.frame.reset()
}

fn (mut l Loop) peer_drop_fd(mut peer Peer) {
	if peer.fd >= 0 {
		l.ctl(C.EPOLL_CTL_DEL, peer.fd, 0)
		C.close(peer.fd)
		l.peers[peer.fd] = unsafe { nil }
		peer.fd = -1
	}
	peer.connecting = false
	peer.out_armed = false
}

// peer_close closes the connection and keeps the Peer for the next one; a fetch
// queued for this upstream then gets a connection of its own.
fn (mut l Loop) peer_close(mut peer Peer) {
	l.peer_drop_fd(mut peer)
	mut p := &l.w.pools[peer.pool]
	for i in 0 .. p.idle.len {
		if voidptr(p.idle[i]) == voidptr(peer) {
			p.idle.delete(i)
			break
		}
	}
	p.open--
	peer.busy = false
	peer.reset_bufs()
	l.w.peer_free << peer // cold: grows to the most peers ever open at once
	for p.queued() > 0 && p.open < p.spec.opts.max_conns {
		mut next := l.w.take_peer(mut p, peer.pool)
		l.w.next_queued(mut p, mut next)
		l.w.ready << next // kick connects it: no recursion when connects keep failing
	}
}

// sweep_peers times out fetches whose reply is late, closes connections idle too
// long, and answers queued fetches that waited out their timeout. It runs once a
// second, which is the timeouts' resolution.
fn (mut l Loop) sweep_peers() {
	for i in 0 .. l.peers.len {
		if isnil(l.peers[i]) {
			continue
		}
		mut peer := l.peers[i]
		if l.now > peer.deadline_ms {
			if peer.busy {
				l.peer_fail(mut peer, .timeout)
			} else {
				l.peer_close(mut peer)
			}
		}
	}
	for id in 0 .. l.w.pools.len {
		mut p := &l.w.pools[id]
		for p.queued() > 0 && p.items[p.qhead].deadline_ms < l.now {
			l.w.fails << Fail{p.items[p.qhead].waiter, .timeout}
			p.qhead++
		}
		p.compact()
	}
	l.kick()
}

// close_peers closes every upstream connection when the worker stops.
fn (mut l Loop) close_peers() {
	for i in 0 .. l.peers.len {
		if !isnil(l.peers[i]) {
			mut peer := l.peers[i]
			l.peer_drop_fd(mut peer)
		}
	}
}
