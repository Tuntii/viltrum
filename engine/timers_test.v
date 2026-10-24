module engine

import rand

fn test_timers_pop_in_due_order() {
	mut t := Timers{}
	rand.seed([u32(7), 9])
	for i in 0 .. 1000 {
		t.push(u64(rand.intn(500) or { 0 }), i, 0, 0)
	}
	mut last := u64(0)
	for t.a.len > 0 {
		x := t.pop()
		assert x.due >= last
		last = x.due
	}
}
