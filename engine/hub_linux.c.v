module engine

#include <sys/eventfd.h>

fn C.eventfd(initval u32, flags int) int

// open gives the Hub one inbox per worker, each with the eventfd its worker polls.
fn (mut h Hub) open(n int) ! {
	mut boxes := []&Inbox{}
	for _ in 0 .. n {
		efd := C.eventfd(0, C.EFD_NONBLOCK | C.EFD_CLOEXEC)
		if efd < 0 {
			for b in boxes {
				C.close(b.efd)
			}
			return error('viltrum: eventfd failed')
		}
		boxes << &Inbox{
			efd: efd
		}
	}
	h.mu.lock()
	h.boxes = boxes
	h.mu.unlock()
}

// close drops the inboxes once the workers are gone; later posts are dropped.
fn (mut h Hub) close() {
	h.mu.lock()
	for b in h.boxes {
		C.close(b.efd)
	}
	h.boxes = []&Inbox{}
	h.mu.unlock()
}
