module engine

import sync
import viltrum.http1

// Hub carries WebSocket messages into the workers from any thread: a publish to a
// topic, or a send to one connection. Each worker owns an Inbox it drains on its
// event loop, so a connection's buffers are only ever touched by its own worker.
@[heap]
pub struct Hub {
mut:
	mu    &sync.RwMutex = sync.new_rwmutex()
	boxes []&Inbox // one per worker while a server runs
}

@[heap]
struct Inbox {
mut:
	mu   &sync.Mutex = sync.new_mutex()
	q    []&http1.WsPost
	efd  int = -1 // the worker polls it; one write wakes it per batch
	woke bool // a wake-up is pending
}

pub fn new_hub() &Hub {
	return &Hub{}
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
