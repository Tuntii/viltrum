module engine

// Timer is a deferred response due on the connection at fd. gen tells a timer for
// an earlier connection on the same fd (closed since) from one for the current one.
struct Timer {
	due u64 // time.sys_mono_now() ns
	fd  int
	gen u32
}

// Timers is a binary min-heap on due. It grows to the most responses ever pending
// on the worker at once and stays there, so pushes allocate only while it grows.
struct Timers {
mut:
	a []Timer
}

fn (mut t Timers) push(due u64, fd int, gen u32) {
	t.a << Timer{
		due: due
		fd:  fd
		gen: gen
	} // cold: grows to the peak pending count once
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
