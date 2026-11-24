# alias_generic: probe for vlang/v#32402

`v run scripts/vbugs/alias_generic/` prints `local 1, mut parameter 2 (want 1 and 2)` and exits 0 on a correct
compiler. On V master it prints `local 0, mut parameter 0` and exits 1: a generic `mut` method called through an
alias that has the same name as the struct it aliases gets a temporary copy as its receiver, so what the method
writes is lost. `viltrum.Ctx` is such an alias (`pub type Ctx = http1.Ctx`), so `c.json(...)` in any handler
marks the copy as answered and the engine answers 500.

CI's V master job runs this probe (`scripts/check.sh`, `VILTRUM_V_MASTER=1`): while it fails, the example handler
tests are skipped with a warning; when V is fixed it passes and they run again.

## Report draft (not posted)

A follow-up comment for vlang/v#32402, which viltrum filed on 2026-11-16. The trigger is narrower than the issue
says, and the reproduction is shorter. Not sent: the user decides whether to post it.

---

**Update: the trigger is an alias named like its target, and the repro is two files**

Still reproduces on `c3befc5` (2026-11-24). V 0.5.2 (`7647ce1`) is correct; first seen on `846d718`.

The receiver is copied when all of these hold:

- the method is generic and takes `mut` (a `&T` receiver is copied too; non-generic methods are fine),
- it is called through a type alias of a struct from another module,
- the alias has the **same short name** as the struct (`type Ctx = inner.Ctx`, `type Foo = inner.Foo`).
  `type Outer = inner.Ctx` or `type Ctx = inner.Inner` work,
It happens through a local variable and through a `mut` parameter alike, and the alias may be declared in `main`
itself. One oddity: through a `mut` parameter, a method named `set` is spared (through a local it is not), which
is how an earlier repro of ours passed and misled us.

`inner/inner.v`:

```v
module inner

pub struct Ctx {
pub mut:
	n int
}

pub fn (mut c Ctx) put[T](status int, v T) {
	c.n = status
}
```

`main.v`:

```v
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
}
```

`v run .` prints `local 0, mut parameter 0 (want 1 and 2)` on master and `local 1, mut parameter 2` on 0.5.2.
The generated call is

```c
inner__Ctx_int__put(&((inner__Ctx[]){*((inner__Ctx*)(c))})[0], 2, 5);
```

where 0.5.2, and master for `type Outer = inner.Ctx`, pass `c`. The copy comes from the `materialize_receiver`
branch of `vlib/v/gen/c/fn.v` (the receiver is an alias-to-struct cast, which `expr_is_addressable` rejects), so
something upstream of it resolves the same-name alias differently from a differently named one. A method defined
on the alias itself, forwarding to a free function, is copied the same way.
