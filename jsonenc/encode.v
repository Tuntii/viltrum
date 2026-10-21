module jsonenc

import math

// encode_into appends the JSON encoding of val to out without allocating and returns
// the number of bytes appended. It is generated per type at compile time, so there is
// no reflection at run time.
//
// V 0.5.2 -prod builds with Boehm pin every by-value struct or array of pointers in
// scope around each call statement: they walk all its pointers and, past 32, take
// the global GC lock. Encoding a 40-item page that way serialized every worker. So
// every call made while a struct or array is in scope is written as `_ = f()`, an
// assignment, which is not pinned. Keep it that way: scripts/gcpin_check.sh fails CI
// on a pin in the hot path.
pub fn encode_into[T](mut out []u8, val T) int {
	start := out.len
	_ = encode(mut out, val)
	return out.len - start
}

fn encode[T](mut out []u8, val T) bool {
	$if T.unaliased_typ is string {
		_ = write_string(mut out, string(val))
	} $else $if T.unaliased_typ is bool {
		if bool(val) {
			_ = push(mut out, 'true')
		} else {
			_ = push(mut out, 'false')
		}
	} $else $if T.unaliased_typ is u64 {
		_ = write_u64(mut out, u64(val))
	} $else $if T.unaliased_typ is $int {
		_ = write_i64(mut out, i64(val))
	} $else $if T.unaliased_typ is f32 {
		_ = write_float(mut out, f64(val), true)
	} $else $if T.unaliased_typ is $float {
		_ = write_float(mut out, f64(val), false)
	} $else $if T.unaliased_typ is $array {
		_ = put(mut out, `[`)
		for i, item in val {
			if i > 0 {
				_ = put(mut out, `,`)
			}
			_ = encode(mut out, item)
		}
		_ = put(mut out, `]`)
	} $else $if T.unaliased_typ is $struct {
		_ = put(mut out, `{`)
		mut first := true
		$for field in T.fields {
			_ = key(mut out, field.name, first)
			first = false
			_ = encode(mut out, val.$(field.name))
		}
		_ = put(mut out, `}`)
	} $else {
		$compile_error('viltrum.jsonenc: unsupported type')
	}
	return true
}

// The writers below append in place while out has room and fall back to <<
// otherwise. A push per byte was a fifth of json-comp's profile: each one is a call
// that rechecks length, capacity and slice flags.

// room reports whether n more bytes fit in out without growing it or unsharing a slice.
@[inline]
fn room(out []u8, n int) bool {
	return out.len + n <= out.cap && !out.flags.has(.is_slice)
}

@[inline]
fn put(mut out []u8, c u8) bool {
	if room(out, 1) {
		unsafe {
			(&u8(out.data))[out.len] = c
			out.len++
		}
	} else {
		out << c
	}
	return true
}

@[inline]
fn put_many(mut out []u8, p &u8, n int) bool {
	if n <= 0 {
		return true
	}
	if room(out, n) {
		unsafe {
			vmemcpy(&u8(out.data) + out.len, p, n)
			out.len += n
		}
	} else {
		unsafe { out.push_many(p, n) }
	}
	return true
}

@[inline]
fn push(mut out []u8, s string) bool {
	return put_many(mut out, s.str, s.len)
}

// key writes a struct field's separator and `"name":` behind one capacity check.
fn key(mut out []u8, name string, first bool) bool {
	n := name.len + 4
	if room(out, n) {
		unsafe {
			mut p := &u8(out.data) + out.len
			mut k := 0
			if !first {
				p[0] = `,`
				k = 1
			}
			p[k] = `"`
			vmemcpy(p + k + 1, name.str, name.len)
			p[k + 1 + name.len] = `"`
			p[k + 2 + name.len] = `:`
			out.len += k + 3 + name.len
		}
		return true
	}
	if !first {
		_ = put(mut out, `,`)
	}
	_ = put(mut out, `"`)
	_ = push(mut out, name)
	_ = put(mut out, `"`)
	return put(mut out, `:`)
}

const hex_digits = '0123456789abcdef'

// write_string escapes per RFC 8259: quote, backslash and control bytes. UTF-8
// passes through unchanged.
fn write_string(mut out []u8, s string) bool {
	_ = put(mut out, `"`)
	mut run := 0
	for i in 0 .. s.len {
		c := s[i]
		if c >= 0x20 && c != `"` && c != `\\` {
			continue
		}
		_ = put_many(mut out, unsafe { s.str + run }, i - run)
		run = i + 1
		_ = put(mut out, `\\`)
		match c {
			`"` {
				_ = put(mut out, `"`)
			}
			`\\` {
				_ = put(mut out, `\\`)
			}
			`\n` {
				_ = put(mut out, `n`)
			}
			`\r` {
				_ = put(mut out, `r`)
			}
			`\t` {
				_ = put(mut out, `t`)
			}
			0x08 {
				_ = put(mut out, `b`)
			}
			0x0c {
				_ = put(mut out, `f`)
			}
			else {
				_ = push(mut out, 'u00')
				_ = put(mut out, hex_digits[c >> 4])
				_ = put(mut out, hex_digits[c & 0xf])
			}
		}
	}
	_ = put_many(mut out, unsafe { s.str + run }, s.len - run)
	_ = put(mut out, `"`)
	return true
}

fn write_u64(mut out []u8, n u64) bool {
	if n == 0 {
		_ = put(mut out, `0`)
		return true
	}
	mut tmp := [20]u8{}
	mut i := 20
	mut v := n
	for v > 0 {
		i--
		tmp[i] = u8(`0` + v % 10)
		v /= 10
	}
	_ = put_many(mut out, &tmp[i], 20 - i)
	return true
}

fn write_i64(mut out []u8, n i64) bool {
	if n < 0 {
		_ = put(mut out, `-`)
		return write_u64(mut out, u64(-(n + 1)) + 1)
	}
	return write_u64(mut out, u64(n))
}

#include <stdlib.h>

fn C.strtod(&char, voidptr) f64

// write_float prints the shortest of %.15g, %.16g, %.17g that parses back to the same
// value (f32: %.6g to %.9g, compared as f32); NaN and infinities are null.
fn write_float(mut out []u8, f f64, is32 bool) bool {
	if math.is_nan(f) || math.is_inf(f, 0) {
		return push(mut out, 'null')
	}
	mut tmp := [32]u8{}
	lo := if is32 { 6 } else { 15 }
	hi := if is32 { 10 } else { 18 }
	mut n := 0
	unsafe {
		for prec in lo .. hi {
			n = C.snprintf(&char(&tmp[0]), 32, c'%.*g', prec, f)
			back := C.strtod(&char(&tmp[0]), nil)
			if (is32 && f32(back) == f32(f)) || back == f {
				break
			}
		}
	}
	_ = put_many(mut out, &tmp[0], n)
	return true
}
