module http1

import os
import time

// again readies c, which keeps its file cache, for the next request raw.
fn again(mut c Ctx, raw string) {
	buf := raw.bytes()
	mut f := Frame{}
	n := frame(buf, mut f, Limits{}) or { panic(err) }
	unsafe {
		c.out.len = 0
	}
	parse_head(buf, f.head_end, mut c.head) or { panic(err) }
	c.begin(view(buf, 0, n))
}

fn static_get(mut c Ctx, dir string, rel string, extra string) string {
	again(mut c, 'GET /${rel} HTTP/1.1\r\nHost: x\r\n${extra}\r\n')
	c.static_file(dir, rel, precompressed: true)
	return c.out.bytestr()
}

fn cache_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'viltrum-fcache-${name}-${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

// Cached copies follow the disk: a rewrite of the same size, a file replaced by
// another with the same size and mtime, a deleted file, a replaced .br copy.
fn test_cache_follows_the_disk() {
	dir := cache_dir('follow')
	defer {
		os.rmdir_all(dir) or {}
	}
	p := os.join_path(dir, 'a.txt')
	os.write_file(p, 'aaaa') or { panic(err) }
	mut c := Ctx.new()
	c.send_date = false
	c.out = []u8{cap: 4096}
	assert static_get(mut c, dir, 'a.txt', '').ends_with('\r\n\r\naaaa')
	assert static_get(mut c, dir, 'a.txt', '').ends_with('\r\n\r\naaaa')
	assert static_get(mut c, dir, 'a.txt', 'Range: bytes=1-2\r\n').ends_with('\r\n\r\naa')
	$if !windows {
		assert c.fcache.len == 1
	}
	time.sleep(20 * time.millisecond) // past the filesystem's timestamp granularity
	os.write_file(p, 'bbbb') or { panic(err) }
	assert static_get(mut c, dir, 'a.txt', '').ends_with('\r\n\r\nbbbb')
	// another inode, with the old size and mtime
	attr := os.stat(p) or { panic(err) }
	tmp := os.join_path(dir, 'a.tmp')
	os.write_file(tmp, 'cccc') or { panic(err) }
	os.utime(tmp, int(attr.atime), int(attr.mtime)) or { panic(err) }
	os.mv(tmp, p) or { panic(err) }
	assert static_get(mut c, dir, 'a.txt', '').ends_with('\r\n\r\ncccc')
	// a .br copy, served from the cache and replaced like the file
	os.write_file(p + '.br', 'BR-1') or { panic(err) }
	assert static_get(mut c, dir, 'a.txt', 'Accept-Encoding: br\r\n').ends_with('\r\n\r\nBR-1')
	assert static_get(mut c, dir, 'a.txt', 'Accept-Encoding: br\r\n').ends_with('\r\n\r\nBR-1')
	time.sleep(20 * time.millisecond)
	os.write_file(p + '.br', 'BR-2') or { panic(err) }
	assert static_get(mut c, dir, 'a.txt', 'Accept-Encoding: br\r\n').ends_with('\r\n\r\nBR-2')
	os.rm(p + '.br') or { panic(err) }
	assert static_get(mut c, dir, 'a.txt', 'Accept-Encoding: br\r\n').ends_with('\r\n\r\ncccc')
	os.rm(p) or { panic(err) }
	assert static_get(mut c, dir, 'a.txt', '').starts_with('HTTP/1.1 404 ')
}

// Past file_cache_max, files are still served, from disk.
fn test_cache_stays_within_its_budget() {
	dir := cache_dir('budget')
	defer {
		os.rmdir_all(dir) or {}
	}
	n := file_cache_max / file_inline_max + 3
	for i in 0 .. n {
		os.write_file(os.join_path(dir, '${i}.bin'), '${i % 10}'.repeat(file_inline_max)) or {
			panic(err)
		}
	}
	mut c := Ctx.new()
	c.send_date = false
	c.out = []u8{cap: file_inline_max + 4096}
	for _ in 0 .. 2 {
		for i in 0 .. n {
			r := static_get(mut c, dir, '${i}.bin', '')
			assert r.starts_with('HTTP/1.1 200 ') && r.ends_with('${i % 10}'.repeat(64)), '${i}'
		}
	}
	assert c.fcache_bytes <= file_cache_max
	$if !windows {
		assert c.fcache.len == file_cache_max / file_inline_max
	}
}
