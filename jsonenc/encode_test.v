module jsonenc

import math
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
