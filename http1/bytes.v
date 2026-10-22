module http1

// Byte helpers for the request hot path. None of them allocates: views share the
// caller's buffer, appends write into capacity the caller owns.

// view returns buf[start..start+len] without copying and without V's slice
// bookkeeping (array.slice marks the parent and costs ~20% of a plaintext request).
// The view does not own its memory: it is valid while buf is neither freed nor moved.
@[inline]
pub fn view(buf []u8, start int, len int) []u8 {
	mut v := unsafe { buf }
	unsafe {
		v.data = &u8(buf.data) + start
		v.len = len
		v.cap = len
		v.flags.clear(.managed)
	}
	return v
}

// str_view is view as a string. It is not NUL-terminated; clone it to keep it.
@[inline]
pub fn str_view(buf []u8, start int, len int) string {
	if len <= 0 {
		return ''
	}
	return unsafe { tos(&u8(buf.data) + start, len) }
}

@[inline]
pub fn append_str(mut out []u8, s string) {
	if s.len > 0 {
		unsafe { out.push_many(s.str, s.len) }
	}
}

@[inline]
pub fn append_bytes(mut out []u8, b []u8) {
	if b.len > 0 {
		unsafe { out.push_many(b.data, b.len) }
	}
}

// append_int writes n in decimal (n.str() would allocate).
pub fn append_int(mut out []u8, n i64) {
	if n == 0 {
		out << `0`
		return
	}
	mut tmp := [20]u8{}
	mut i := 20
	neg := n < 0
	mut v := if neg { u64(-(n + 1)) + 1 } else { u64(n) }
	for v > 0 {
		i--
		tmp[i] = u8(`0` + v % 10)
		v /= 10
	}
	if neg {
		out << `-`
	}
	unsafe { out.push_many(&tmp[i], 20 - i) }
}

@[inline]
pub fn lower(c u8) u8 {
	return if c >= `A` && c <= `Z` { c + 32 } else { c }
}

// eq_ci compares s with an ASCII-lowercase literal, ignoring the case of s.
@[direct_array_access]
pub fn eq_ci(s string, lower_lit string) bool {
	if s.len != lower_lit.len {
		return false
	}
	for i in 0 .. s.len {
		if lower(s[i]) != lower_lit[i] {
			return false
		}
	}
	return true
}

// tchars marks the bytes that may appear in an RFC 9110 token.
const tchars = make_tchars()

fn make_tchars() [256]bool {
	mut t := [256]bool{}
	for c in 0 .. 256 {
		b := u8(c)
		t[c] = (b >= `a` && b <= `z`) || (b >= `A` && b <= `Z`)
			|| (b >= `0` && b <= `9`)
			|| b in [`!`, `#`, `$`, `%`, `&`, `'`, `*`, `+`, `-`, `.`, `^`, `_`, `\``, `|`, `~`]
	}
	return t
}

// is_tchar reports whether c may appear in an RFC 9110 token.
@[inline]
pub fn is_tchar(c u8) bool {
	return tchars[c]
}

// parse_i64 parses an optionally signed decimal, ignoring surrounding whitespace.
// At most 18 digits, so it can never overflow.
pub fn parse_i64(s string) ?i64 {
	mut i := 0
	mut j := s.len
	for i < j && (s[i] == ` ` || s[i] == `\t`) {
		i++
	}
	for j > i && (s[j - 1] == ` ` || s[j - 1] == `\t` || s[j - 1] == `\r` || s[j - 1] == `\n`) {
		j--
	}
	if i == j {
		return none
	}
	mut neg := false
	if s[i] == `-` || s[i] == `+` {
		neg = s[i] == `-`
		i++
		if i == j {
			return none
		}
	}
	if j - i > 18 {
		return none
	}
	mut n := i64(0)
	for k in i .. j {
		c := s[k]
		if c < `0` || c > `9` {
			return none
		}
		n = n * 10 + i64(c - `0`)
	}
	return if neg { -n } else { n }
}

// allocated_bytes is the GC's running total of allocated bytes. Tests diff it
// around a batch of requests to prove the hot path allocates nothing.
pub fn allocated_bytes() u64 {
	return u64(gc_heap_usage().total_bytes)
}
