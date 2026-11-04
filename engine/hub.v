module engine

import sync
import viltrum.http1

// Hub carries WebSocket messages into the workers from any thread: a publish to a
// topic, or a send to one connection. Each worker owns an Inbox it drains on its
// event loop, so a connection's buffers are only ever touched by its own worker.
// It also carries App.wake: park_cap slots, indexed by the low 32 bits of a token
// (never 0). The high 32 bits are the caller's generation, so a late wake for a
// finished request cannot answer the next one that reused the slot.
const park_cap = 8192

struct Park {
mut:
	state  u8 // 0 empty, 1 wake arrived before the request parked, 2 parked
	req    u32
	worker int
	fd     int
	gen    u32
	serial u32
}

// Kick is a parked HTTP/1.1 request whose wake has arrived.
struct Kick {
	fd     int
	gen    u32
	serial u32
}

@[heap]
struct Parks {
mut:
	mu &sync.Mutex = sync.new_mutex()
	a  []Park
}

fn new_parks() &Parks {
	return &Parks{
		a: []Park{len: park_cap}
	}
}

@[heap]
pub struct Hub {
mut:
	mu    &sync.RwMutex = sync.new_rwmutex()
	boxes []&Inbox // one per worker while a server runs
	parks &Parks = new_parks()
}

@[heap]
struct Inbox {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	q     []&http1.WsPost
	kicks []Kick
	efd   int = -1 // the worker polls it; one write wakes it per batch
	woke  bool // a wake-up is pending
}

pub fn new_hub() &Hub {
	return &Hub{}
}

// park_at splits a wake token. -1 when it cannot name a slot.
fn park_at(token u64) (int, u32) {
	idx := int(u32(token))
	if idx <= 0 || idx >= park_cap {
		return -1, 0
	}
	return idx, u32(token >> 32)
}

// note records that token is parked on this connection. true means wake already
// ran, so the caller answers on this turn instead of waiting for the timer.
fn (h &Hub) note(token u64, worker int, fd int, gen u32, serial u32) bool {
	idx, req := park_at(token)
	if idx < 0 {
		return false
	}
	mut p := h.parks
	p.mu.lock()
	mut fire := false
	if p.a[idx].state == 1 && p.a[idx].req == req {
		p.a[idx].state = 0
		fire = true
	} else {
		p.a[idx].state = 2
		p.a[idx].req = req
		p.a[idx].worker = worker
		p.a[idx].fd = fd
		p.a[idx].gen = gen
		p.a[idx].serial = serial
	}
	p.mu.unlock()
	return fire
}

// clear drops a park when the request is answered by its timer, or by the kick
// that already took it. An early wake for a later generation is left alone.
fn (h &Hub) clear(token u64) {
	idx, req := park_at(token)
	if idx < 0 {
		return
	}
	mut p := h.parks
	p.mu.lock()
	if p.a[idx].state == 2 && p.a[idx].req == req {
		p.a[idx].state = 0
	}
	p.mu.unlock()
}

// wake asks the worker that parked token to answer it now. Safe from any
// thread. A token that is not parked yet is remembered, and note answers on
// the turn the request does park. A token nobody parks is ignored.
pub fn (h &Hub) wake(token u64) {
	idx, req := park_at(token)
	if idx < 0 {
		return
	}
	mut p := h.parks
	p.mu.lock()
	if p.a[idx].state == 2 && p.a[idx].req == req {
		k := Kick{
			fd:     p.a[idx].fd
			gen:    p.a[idx].gen
			serial: p.a[idx].serial
		}
		worker := p.a[idx].worker
		p.a[idx].state = 0
		p.mu.unlock()
		h.mu.rlock()
		if worker >= 0 && worker < h.boxes.len {
			mut b := h.boxes[worker]
			b.put_kick(k)
		}
		h.mu.runlock()
		return
	}
	if p.a[idx].state != 2 {
		p.a[idx].state = 1
		p.a[idx].req = req
	}
	p.mu.unlock()
}

// post queues p for the workers it concerns: all of them for a topic, the target's
// for a single connection. Without a running server it is dropped.
pub fn (h &Hub) post(p &http1.WsPost) {
	h.mu.rlock()
	for i in 0 .. h.boxes.len {
		if p.topic.len == 0 && i != p.to.worker {
			continue
		}
		mut b := h.boxes[i]
		b.put(p)
	}
	h.mu.runlock()
}

fn (mut b Inbox) put(p &http1.WsPost) {
	b.mu.lock()
	b.q << p
	wake := !b.woke
	b.woke = true
	b.mu.unlock()
	if wake && b.efd >= 0 {
		one := u64(1)
		C.write(b.efd, &one, 8)
	}
}

// take moves what is queued into out, which must be empty, and leaves out's old
// storage as the queue, so neither side allocates once both have grown.
fn (mut b Inbox) take(mut out []&http1.WsPost) {
	b.mu.lock()
	unsafe {
		out, b.q = b.q, out
	}
	b.woke = false
	b.mu.unlock()
}

fn (mut b Inbox) put_kick(k Kick) {
	b.mu.lock()
	b.kicks << k // cold: grows to the peak number of wakes queued at once
	wake := !b.woke
	b.woke = true
	b.mu.unlock()
	if wake && b.efd >= 0 {
		one := u64(1)
		C.write(b.efd, &one, 8)
	}
}

// take_kicks is take for wakes. out must be empty; its storage becomes the queue.
fn (mut b Inbox) take_kicks(mut out []Kick) {
	b.mu.lock()
	unsafe {
		out, b.kicks = b.kicks, out
	}
	b.woke = false
	b.mu.unlock()
}
