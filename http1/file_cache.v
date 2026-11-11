module http1

// The static file cache: static_file_at keeps the files it serves inline (up to
// file_inline_max) in memory, one copy per worker, so no lock is taken. Each request
// still stats the file, and a copy is used only while stat says what it said when
// the copy was read (size, mtime, inode, ctime): a file rewritten or replaced on disk
// is read again by the next request that asks for it. A hit costs one stat instead
// of open, fstat, read and close.

// file_cache_max is what a worker's copies may hold in all; past it, files are read
// from disk on each request as before.
// shortcut: no eviction, so a tree larger than this keeps serving its first files from
// memory and the rest from disk; add LRU if real trees outgrow it.
pub const file_cache_max = 4 * 1024 * 1024

struct CachedFile {
mut:
	info C.viltrum_file_info
	data []u8
}

// stat_pbuf describes the path in pbuf in info without opening it.
fn (mut c Ctx) stat_pbuf(info &C.viltrum_file_info) {
	c.pbuf << 0
	C.viltrum_file_stat(c.pbuf.data, info)
	unsafe {
		c.pbuf.len--
	}
}

// load_pbuf is the regular file in pbuf, which stat_pbuf described in info: an fcache
// slot holding its bytes (fd -1), or an open fd (slot -1) for one not cached. info
// ends up describing what is served. -1, -1 when it can no longer be opened.
fn (mut c Ctx) load_pbuf(info &C.viltrum_file_info) (int, int) {
	key := str_view(c.pbuf, 0, c.pbuf.len)
	slot := c.fcache_idx[key] - 1 // slots are kept +1: `or {}` on a miss would allocate its error
	if slot >= 0 && info.ino >= 0 && same_file(&c.fcache[slot].info, info) {
		return -1, slot
	}
	fd := c.open_pbuf(info)
	if fd >= 0 && info.kind != 1 {
		C.viltrum_file_close(fd) // no longer a regular file since the stat
		return -1, -1
	}
	if fd < 0 || info.ino < 0 || info.size > file_inline_max {
		return fd, -1
	}
	s := c.cache_fd(fd, info, slot)
	return if s >= 0 { -1 } else { fd }, s
}

// cache_fd reads the file at fd into slot (a new one for -1) and closes it: the slot,
// or -1 with fd left open when the budget is spent or the read comes up short.
fn (mut c Ctx) cache_fd(fd int, info &C.viltrum_file_info, slot int) int {
	n := int(info.size)
	old := if slot >= 0 { c.fcache[slot].data.cap } else { 0 }
	if n > old && c.fcache_bytes + n - old > file_cache_max {
		return -1
	}
	mut s := slot
	if s < 0 {
		c.fcache << CachedFile{} // cold: once per file
		s = c.fcache.len - 1
		c.fcache_idx[str_view(c.pbuf, 0, c.pbuf.len).clone()] = s + 1
	}
	mut e := &c.fcache[s]
	if e.data.cap < n {
		c.fcache_bytes += n - e.data.cap
		e.data = []u8{len: n} // cold: a new or grown file
	}
	unsafe {
		e.data.len = n
	}
	if read_at(fd, e.data.data, n, 0) != n {
		e.info.kind = 0 // never matches: read again next time
		return -1
	}
	C.viltrum_file_close(fd)
	e.info = *info
	return s
}

// same_file reports whether a and b describe the same bytes on disk.
fn same_file(a &C.viltrum_file_info, b &C.viltrum_file_info) bool {
	return a.kind == 1 && a.size == b.size && a.mtime == b.mtime && a.mtime_ns == b.mtime_ns
		&& a.ino == b.ino && a.ctime == b.ctime && a.ctime_ns == b.ctime_ns
}
