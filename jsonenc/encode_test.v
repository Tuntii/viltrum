module jsonenc

import math
import time
import x.json2

struct Rating {
	score int
	count int
}

struct Item {
	id       int
	name     string
	category string
	price    int
	quantity int
	active   bool
	tags     []string
	rating   Rating
	total    i64
}

struct Page {
	items []Item
	count int
}

fn enc[T](v T) string {
	mut out := []u8{}
	encode_into(mut out, v)
	return out.bytestr()
}

fn sample() Page {
	a := Item{
		id:       1
		name:     'Alpha Widget'
		category: 'electronics'
		price:    328
		quantity: 15
		active:   true
		tags:     ['sale', 'new']
		rating:   Rating{
			score: 48
			count: 53
		}
		total:    4920
	}
	b := Item{
		id:       2
		name:     'Pro Valve'
		category: 'tools'
		price:    347
		quantity: 95
		rating:   Rating{
			score: 15
			count: 259
		}
		total:    32965
	}
	return Page{
		items: [a, b]
		count: 2
	}
}

fn test_matches_vlib_json_for_plain_data() {
	p := sample()
	assert enc(p) == json2.encode(p, escape_unicode: true)
	assert enc([1, 2, 3]) == '[1,2,3]'
	assert enc([]int{}) == '[]'
	assert enc(true) == 'true'
	assert enc(u64(18446744073709551615)) == '18446744073709551615'
	assert enc(i64(-9223372036854775807 - 1)) == '-9223372036854775808'
}

struct Event {
	name string
	at   time.Time
}

// time.Time holds a &Location on V master, which a field walk cannot encode (issue #107).
fn test_time_matches_vlib_json() {
	t := time.unix(1793323412)
	assert enc(t) == '"2026-10-30T01:23:32.000Z"'
	ev := Event{
		name: 'deploy'
		at:   t
	}
	assert enc(ev) == json2.encode(ev)
	assert enc([t]) == json2.encode([t])
	now := time.now()
	assert enc(now) == json2.encode(now)
}

enum Level {
	low
	high
}

struct Mixed {
	tags  map[string]int
	ids   map[int]string
	level Level
	note  ?string
	gone  ?int
	next  &Rating = unsafe { nil }
}

// Maps, enums, options and pointers were a compile error before.
fn test_maps_enums_options_pointers_match_vlib_json() {
	m := Mixed{
		tags:  {
			'a"b': 1
			'c':   2
		}
		ids:   {
			7: 'x'
		}
		level: .high
		note:  'hi'
		next:  &Rating{
			score: 3
			count: 4
		}
	}
	assert enc(m) == json2.encode(m)
	assert enc({
		'msg': 'ok'
	}) == '{"msg":"ok"}'
	assert enc(Level.low) == '"low"'
	assert enc(Mixed{}) == json2.encode(Mixed{})
}

enum Tone {
	soft @[json: 'SOFT']
	loud
}

type Shape = Rating | Tone | int | string | []int

interface Area {
	area() int
}

struct Square {
	side int
}

fn (s Square) area() int {
	return s.side * s.side
}

struct Base {
	id   int
	kind string @[json: 'type']
}

struct Tagged {
	Base
	name   string @[json: 'full_name']
	secret string @[skip]
	hidden string @[json: '-']
	blank  string @[omitempty]
	zero   int    @[omitempty]
	list   []int  @[omitempty]
	opt    ?int   @[json: "o"]
	must   ?int   @[json_null]
	tone   Tone
	shapes []Shape
	shape  Shape = 0
	area   Area   = Square{2}
}

// Field attributes, embedded structs, sum types and interfaces, as x.json2 writes them.
fn test_attrs_embeds_sumtypes_match_vlib_json() {
	t := Tagged{
		id:     7
		kind:   'k'
		name:   'n'
		secret: 's'
		hidden: 'h'
		opt:    3
		shapes: [Shape(Rating{
			score: 1
			count: 2
		}), Tone.soft, 5, 'x', [1, 2]]
		shape:  Rating{}
	}
	assert enc(t) == json2.encode(t)
	assert enc(Tagged{}) == json2.encode(Tagged{})
	assert enc(Tone.soft) == '"SOFT"'
	assert enc(Shape(4)) == '4'
}

fn test_strings_are_escaped() {
	assert enc('plain') == '"plain"'
	assert enc('q"b\\s/') == '"q\\"b\\\\s/"'
	assert enc('a\nb\rc\td\x08e\x0cf') == '"a\\nb\\rc\\td\\be\\ff"'
	assert enc('\x01\x1f') == '"\\u0001\\u001f"'
	assert enc('café') == '"café"'
}

fn test_floats_round_trip() {
	for f in [0.0, 1.5, -2.25, 0.1, 1e300, 123456.789] {
		assert enc(f).f64() == f, f.str()
	}
	assert enc(0.1) == '0.1', enc(0.1)
	assert enc(29.99) == '29.99', enc(29.99)
	assert enc(f32(0.1)) == '0.1'
	third := 1.0 / 3.0
	assert enc(third).f64() == third
	assert enc(1e300).f64() == 1e300
	assert enc(math.nan()) == 'null'
	assert enc(math.inf(1)) == 'null'
}

fn test_encoding_allocates_nothing() {
	p := sample()
	mut out := []u8{cap: 4096}
	encode_into(mut out, p)
	before := u64(gc_heap_usage().total_bytes)
	for _ in 0 .. 10000 {
		unsafe {
			out.len = 0
		}
		encode_into(mut out, p)
		encode_into(mut out, 3.25)
	}
	assert u64(gc_heap_usage().total_bytes) - before == 0
}
