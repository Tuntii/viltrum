module jsonenc

import math
import time

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
	// Options and pointers come first: the checks below also hold for an option or a
	// pointer of a matching type.
	$if T is $interface {
		// As x.json2 does.
		_ = push(mut out, 'null')
	} $else $if T is $option {
		if val == none {
			_ = push(mut out, 'null')
		} else {
			_ = encode(mut out, unwrap(val))
		}
	} $else $if T is $pointer {
		if voidptr(val) == unsafe { nil } {
			_ = push(mut out, 'null')
		} else {
			_ = encode(mut out, *val)
		}
	} $else $if T.unaliased_typ is string {
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
	} $else $if T.unaliased_typ is $map {
		_ = put(mut out, `{`)
		mut first := true
		for k, v in val {
			if !first {
				_ = put(mut out, `,`)
			}
			first = false
			$if k is string {
				_ = write_string(mut out, k)
			} $else $if k is rune {
				_ = write_string(mut out, '${k}') // cold: rune keys are rare
			} $else $if k is u64 {
				_ = put(mut out, `"`)
				_ = write_u64(mut out, k)
				_ = put(mut out, `"`)
			} $else $if k is $int {
				_ = put(mut out, `"`)
				_ = write_i64(mut out, i64(k))
				_ = put(mut out, `"`)
			} $else {
				_ = write_string(mut out, '${k}') // cold: enum and other keys are rare
			}
			_ = put(mut out, `:`)
			_ = encode(mut out, v)
		}
		_ = put(mut out, `}`)
	} $else $if T.unaliased_typ is $enum {
		// By name or its @[json: 'name'], as x.json2 does by default.
		$for member in T.values {
			if member.value == val {
				name, _, _, _ := field_attrs(member.name, member.attrs)
				_ = write_string(mut out, name)
			}
		}
	} $else $if T.unaliased_typ is $sumtype {
		$for variant in T.variants {
			if val is variant {
				_ = encode_variant(mut out, val)
			}
		}
	} $else $if T.unaliased_typ is time.Time {
		// As vlib json does. Walking its fields fails on V master, where Time holds a &Location.
		_ = write_string(mut out, time.Time(val).format_rfc3339())
	} $else $if T.unaliased_typ is $struct {
		_ = put(mut out, `{`)
		_ = fields(mut out, val, true)
		_ = put(mut out, `}`)
	} $else {
		$compile_error('viltrum.jsonenc: unsupported type')
	}
	return true
}

// encode_variant writes a sum type's value; a struct gets a `"_type"` member naming
// it, as x.json2 does.
fn encode_variant[T](mut out []u8, val T) bool {
	$if T.unaliased_typ is time.Time {
		_ = encode(mut out, val)
	} $else $if T.unaliased_typ is $struct {
		_ = put(mut out, `{`)
		first := fields(mut out, val, true)
		_ = key(mut out, '_type', first)
		_ = write_string(mut out, short_name(T.name))
		_ = put(mut out, `}`)
	} $else {
		_ = encode(mut out, val)
	}
	return true
}

// fields writes val's fields as object members, an embedded struct's in its place as
// x.json2 does, and returns whether it wrote none while first was set.
// shortcut: an embedded field named like an outer one is written twice, where x.json2
// prefixes it; handle that when someone needs it.
fn fields[T](mut out []u8, val T, was_first bool) bool {
	mut first := was_first
	$for field in T.fields {
		$if field.is_embed {
			first = fields(mut out, val.$(field.name), first)
		} $else {
			name, skip, omitempty, keep_null := field_attrs(field.name, field.attrs)
			if !skip && keep(val.$(field.name), omitempty, keep_null) {
				_ = key(mut out, name, first)
				first = false
				_ = encode(mut out, val.$(field.name))
			}
		}
	}
	return first
}

// field_attrs reads a field's (or enum value's) attributes as x.json2 does: its key,
// and whether to skip it, leave it out when empty, or write null for none. A field
// without attributes costs a length check.
fn field_attrs(name string, attrs []string) (string, bool, bool, bool) {
	mut key_name := name
	mut omitempty := false
	mut keep_null := false
	for a in attrs {
		if a == 'skip' {
			return name, true, false, false
		} else if a == 'omitempty' {
			omitempty = true
		} else if a == 'required' || a == 'json_null' {
			keep_null = true
		} else if a.starts_with('json:') {
			key_name = attr_value(a)
			if key_name == '-' {
				return name, true, false, false
			}
		}
	}
	return key_name, false, omitempty, keep_null
}

// attr_value is the text after `json:`, unquoted, as a view into a.
fn attr_value(a string) string {
	mut i := 5
	mut j := a.len
	for i < j && a[i] == ` ` {
		i++
	}
	for j > i && a[j - 1] == ` ` {
		j--
	}
	if j - i > 1 && (a[i] == `'` || a[i] == `"`) && a[j - 1] == a[i] {
		i++
		j--
	}
	return unsafe { tos(a.str + i, j - i) }
}

// short_name drops the module from a type name, as x.json2's `_type` does.
fn short_name(s string) string {
	i := s.last_index_u8(`.`) + 1
	return unsafe { tos(s.str + i, s.len - i) }
}

// keep reports whether a struct field is written: never when nil, when none only
// with @[required] or @[json_null], when empty not with @[omitempty].
@[inline]
fn keep[T](val T, omitempty bool, keep_null bool) bool {
	if is_none(val) {
		return keep_null && !omitempty
	}
	if is_nil(val) {
		return false
	}
	return !omitempty || !is_empty(val)
}

// is_none and is_nil only return under $if: V 0.5.2 miscompiles an `if val == none`
// branch in an option's $if.
@[inline]
fn is_none[T](val T) bool {
	$if T is $option {
		return val == none
	}
	return false
}

@[inline]
fn is_nil[T](val T) bool {
	$if T is $pointer {
		return voidptr(val) == unsafe { nil }
	}
	return false
}

// is_empty is x.json2's test for @[omitempty]: zero, '', false, no items, none, nil,
// the first enum value, or a struct equal to its defaults.
fn is_empty[T](val T) bool {
	$if T is $option {
		return val == none || is_empty(unwrap(val))
	} $else $if T is $pointer {
		return voidptr(val) == unsafe { nil }
	} $else $if T.unaliased_typ is string {
		return string(val) == ''
	} $else $if T.unaliased_typ is bool {
		return !bool(val)
	} $else $if T.unaliased_typ is $int || T.unaliased_typ is $float {
		return val == 0
	} $else $if T.unaliased_typ is $array || T.unaliased_typ is $map {
		return val.len == 0
	} $else $if T.unaliased_typ is $enum {
		return val == unsafe { T(0) }
	} $else $if T.unaliased_typ is $struct {
		return val == T{}
	}
	return false
}

fn unwrap[T](val ?T) T {
	return val or { T{} }
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
			C.memcpy(&u8(out.data) + out.len, p, n)
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
			C.memcpy(p + k + 1, name.str, name.len)
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
// passes through unchanged. A string with nothing to escape, the usual case, goes
// out quotes and all behind one capacity check.
@[direct_array_access]
fn write_string(mut out []u8, s string) bool {
	if room(out, s.len + 2) {
		mut clean := true
		for i in 0 .. s.len {
			c := s[i]
			if c < 0x20 || c == `"` || c == `\\` {
				clean = false
				break
			}
		}
		if clean {
			unsafe {
				mut p := &u8(out.data) + out.len
				p[0] = `"`
				C.memcpy(p + 1, s.str, s.len)
				p[s.len + 1] = `"`
				out.len += s.len + 2
			}
			return true
		}
	}
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

// digit_pairs is "00".."99", for writing integers two digits per division.
const digit_pairs = make_digit_pairs()

fn make_digit_pairs() [200]u8 {
	mut t := [200]u8{}
	for k in 0 .. 100 {
		t[2 * k] = u8(`0` + k / 10)
		t[2 * k + 1] = u8(`0` + k % 10)
	}
	return t
}

@[direct_array_access]
fn write_u64(mut out []u8, n u64) bool {
	mut tmp := [20]u8{}
	mut i := 20
	mut v := n
	for v >= 100 {
		r := int(v % 100) * 2
		v /= 100
		i -= 2
		tmp[i] = digit_pairs[r]
		tmp[i + 1] = digit_pairs[r + 1]
	}
	if v >= 10 {
		r := int(v) * 2
		i -= 2
		tmp[i] = digit_pairs[r]
		tmp[i + 1] = digit_pairs[r + 1]
	} else {
		i--
		tmp[i] = u8(`0` + v)
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
