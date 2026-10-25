module engine

import viltrum.http1

// Timer is a deferred response due on the connection at fd, or with tick set a
// streaming response's timer (Stream.after). gen tells a timer for an earlier
// connection on the same fd (closed since) from one for the current one. stream is
// the HTTP/2 stream it answers, 0 for an HTTP/1.1 deferred response; for a tick, the
// stream it runs on.
struct Timer {
	due    u64 // time.sys_mono_now() ns
	fd     int
	gen    u32
	stream u32
	// the tick's http1.StreamTick, 0 for none. Kept as an integer: a function is code,
	// which the GC never needs to see, and a pointer field would make every Timer in
	// scope a GC scope pin under V -prod (see jsonenc.encode_into).
	tick u64
	arg  u64
}

// cb is the timer's tick; call it only when tick != 0.
@[inline]
fn (t &Timer) cb() http1.StreamTick {
	return unsafe { http1.StreamTick(voidptr(t.tick)) }
}

// Timers is a binary min-heap on due. It grows to the most responses ever pending
// on the worker at once and stays there, so pushes allocate only while it grows.
struct Timers {
mut:
	a []Timer
}

fn (mut t Timers) push(due u64, fd int, gen u32, stream u32) {
	t.a << Timer{
		due:    due
		fd:     fd
		gen:    gen
		stream: stream
	} // cold: grows to the peak pending count once
	t.up()
}

fn (mut t Timers) push_tick(due u64, fd int, gen u32, stream u32, cb http1.StreamTick, arg u64) {
	t.a << Timer{
		due:    due
		fd:     fd
		gen:    gen
		stream: stream
		tick:   u64(voidptr(cb))
		arg:    arg
	} // cold: as in push
	t.up()
}

// up moves the last timer up to its place.
fn (mut t Timers) up() {
	mut i := t.a.len - 1
	for i > 0 {
		p := (i - 1) / 2
		if t.a[p].due <= t.a[i].due {
			break
		}
		t.swap(i, p)
		i = p
	}
}

fn (t &Timers) due_at() u64 {
	return t.a[0].due
}

// pop removes the earliest timer; the heap must not be empty.
fn (mut t Timers) pop() Timer {
	top := t.a[0]
	last := t.a.len - 1
	t.a[0] = t.a[last]
	unsafe {
		t.a.len = last
	}
	mut i := 0
	for {
		l := 2 * i + 1
		if l >= last {
			break
		}
		mut m := l
		if l + 1 < last && t.a[l + 1].due < t.a[l].due {
			m = l + 1
		}
		if t.a[i].due <= t.a[m].due {
			break
		}
		t.swap(i, m)
		i = m
	}
	return top
}

fn (mut t Timers) swap(i int, j int) {
	x := t.a[i]
	t.a[i] = t.a[j]
	t.a[j] = x
}
