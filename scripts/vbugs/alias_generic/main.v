// Probe for vlang/v#32402: a generic `mut` method called through a type alias that
// has the same name as the struct it aliases (here `Ctx = inner.Ctx`, as
// `viltrum.Ctx = http1.Ctx`) must change the value it was called on. V master passes
// a temporary copy as the receiver instead (seen since 846d718, 2026-11-16), so
// `c.json(...)` in a handler answers 500 there. Exits 0 when the compiler is right,
// 1 when it shows the bug. scripts/check.sh runs it in CI's V master job.
module main

import inner

type Ctx = inner.Ctx

fn change(mut c Ctx) {
	c.put(2, 5)
}

fn main() {
	mut local := Ctx{}
	local.put(1, 5)
	mut param := Ctx{}
	change(mut param)
	println('local ${local.n}, mut parameter ${param.n} (want 1 and 2)')
	exit(if local.n == 1 && param.n == 2 { 0 } else { 1 })
}
