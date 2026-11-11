module engine

import time
import viltrum.http1

// The HTTP client (Ctx.fetch): upstream connections ("peers") on the worker's own
// event loop, pooled per worker and upstream. The design is docs/design/1.x-client.md.
// This file is the part that touches no socket: pools, queues, writing requests.
// The event loop drives the sockets (client_linux.c.v).

// Waiter is what a fetch answers: an HTTP/1.1 connection, or one stream of an
// HTTP/2 one. A connection closed meanwhile has another gen, or none.
struct Waiter {
	fd     int = -1
	gen    u32
	stream u32
}

struct Fail {
	waiter Waiter
	err    http1.FetchError
}

// Peer is one connection to an upstream. It keeps its buffers across requests:
// a worker has at most max_conns of them per upstream.
@[heap]
struct Peer {
mut:
	fd          int = -1
	pool        int
	rbuf        []u8
	wbuf        []u8 // the request, kept whole until its reply so it can be sent again
	woff        int
	frame       http1.ReplyFrame
	head        bool // the request is HEAD: its reply has no body
	idem        bool // the request may be sent again on a new connection
	retried     bool
	waiter      Waiter
	busy        bool
	connecting  bool
	out_armed   bool
	deadline_ms i64 // the reply's, while busy; the idle timeout's, while idle
}

fn new_peer(pool int) &Peer {
	return &Peer{
		pool: pool
		rbuf: []u8{cap: read_buf_size}
		wbuf: []u8{cap: 2048}
	}
}

// Queued is a fetch waiting for a connection; its request is Pool.q[off..off + len].
struct Queued {
	waiter      Waiter
	off         int
	len         int
	head        bool
	idem        bool
	deadline_ms i64
}

// Pool is one worker's connections to one upstream.
struct Pool {
mut:
	spec  UpstreamSpec
	idle  []&Peer // most recently used last
	open  int     // connections open or connecting, idle ones included
	q     []u8
	items []Queued
	qhead int
}

fn (p &Pool) queued() int {
	return p.items.len - p.qhead
}

fn idempotent(m http1.Method) bool {
	return m == .get || m == .head || m == .put || m == .delete || m == .options
}

// fetch_start sends the request the Ctx's fetch asked for, or queues it; wt is the
// request or stream that waits for the reply. The event loop connects and writes
// (ready) or answers at once (fails) on this turn.
fn (mut w Worker) fetch_start(wt Waiter) {
	mut x := &w.ctx
	x.fetching = false
	id := x.fetch_up
	if id < 0 || id >= w.pools.len {
		w.fails << Fail{wt, .connect}
		return
	}
	if !x.fetch_valid() {
		w.fails << Fail{wt, .protocol}
		return
	}
	mut p := &w.pools[id]
	head := x.fetch_method == .head
	idem := idempotent(x.fetch_method)
	if p.idle.len > 0 || p.open < p.spec.opts.max_conns {
		mut peer := w.take_peer(mut p, id)
		x.write_fetch(mut peer.wbuf, p.spec.host)
		peer.begin(wt, head, idem)
		peer.deadline_ms = time.ticks() + p.spec.opts.timeout.milliseconds()
		w.ready << peer
		return
	}
	if p.queued() >= p.spec.opts.max_queue {
		w.fails << Fail{wt, .busy}
		return
	}
	off := p.q.len
	x.write_fetch(mut p.q, p.spec.host)
	p.items << Queued{
		waiter:      wt
		off:         off
		len:         p.q.len - off
		head:        head
		idem:        idem
		deadline_ms: time.ticks() + p.spec.opts.timeout.milliseconds()
	} // cold: grows to the most fetches ever queued at once
}

// take_peer is an idle connection, or a new one (not connected yet) when none is.
fn (mut w Worker) take_peer(mut p Pool, id int) &Peer {
	if p.idle.len > 0 {
		return p.idle.pop()
	}
	p.open++
	if w.peer_free.len > 0 {
		mut peer := w.peer_free.pop()
		peer.pool = id
		return peer
	}
	return new_peer(id) // cold: past the most connections this worker ever had open
}

fn (mut peer Peer) begin(wt Waiter, head bool, idem bool) {
	peer.waiter = wt
	peer.head = head
	peer.idem = idem
	peer.retried = false
	peer.busy = true
	peer.woff = 0
	peer.frame.reset()
	unsafe {
		peer.rbuf.len = 0
	}
}

// next_queued moves the oldest queued fetch into peer, which is free; false when
// none waits.
fn (mut w Worker) next_queued(mut p Pool, mut peer Peer) bool {
	if p.queued() == 0 {
		return false
	}
	it := p.items[p.qhead]
	p.qhead++
	unsafe {
		peer.wbuf.len = 0
		peer.wbuf.push_many(&u8(p.q.data) + it.off, it.len)
	}
	peer.begin(it.waiter, it.head, it.idem)
	peer.deadline_ms = it.deadline_ms
	p.compact()
	return true
}

// compact drops the queue's front once half of it is taken, so the queue's bytes
// stay bounded however long it never empties.
fn (mut p Pool) compact() {
	if p.qhead == p.items.len {
		unsafe {
			p.q.len = 0
			p.items.len = 0
		}
		p.qhead = 0
		return
	}
	if p.qhead * 2 < p.items.len {
		return
	}
	cut := p.items[p.qhead].off
	rest := p.q.len - cut
	unsafe {
		C.memmove(p.q.data, &u8(p.q.data) + cut, rest)
		p.q.len = rest
	}
	n := p.items.len - p.qhead
	for i in 0 .. n {
		it := p.items[p.qhead + i]
		p.items[i] = Queued{
			...it
			off: it.off - cut
		}
	}
	unsafe {
		p.items.len = n
	}
	p.qhead = 0
}

// reply_to sets what the next resumed fetch callback reads (Ctx.fetched).
fn (mut w Worker) reply_to(f http1.Fetched, head []u8) {
	w.ctx.reply = f
	w.ctx.reply_head = head
}

// reply_done forgets the reply once its callback returned.
fn (mut w Worker) reply_done() {
	w.ctx.reply = http1.Fetched{}
	w.ctx.reply_head = http1.view(w.ctx.buf, 0, 0)
}
