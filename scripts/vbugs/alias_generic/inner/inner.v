module inner

pub struct Ctx {
pub mut:
	n int
}

// `put`: V master spares a method named `set` on a mut parameter, so not that name
pub fn (mut c Ctx) put[T](status int, v T) {
	c.n = status
}
