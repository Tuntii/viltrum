// First-party multi-conn masked WebSocket load client (issue #7).
// Standalone binary; not part of the viltrum library.
// Usage: ws_load_client [host:port]   default 127.0.0.1:18085
module main

import encoding.base64
import net
import os
import rand
import sync
import time

struct WorkerResult {
	ok int
	dt f64 // seconds (wall for this worker only)
}

fn main() {
	addr := if os.args.len > 1 { os.args[1] } else { '127.0.0.1:18085' }
	// Warm one connection
	warm := run_worker(addr, 50, []u8{len: 64, init: `x`}) or {
		eprintln('warm failed: ${err}')
		exit(1)
	}
	if warm.ok < 50 {
		eprintln('warm incomplete: ${warm.ok}/50')
		exit(1)
	}

	mut out := map[string]string{}

	// A: single conn 20k × 64 B
	{
		payload := []u8{len: 64, init: `x`}
		r := run_worker(addr, 20000, payload) or { panic(err) }
		msg_s := f64(r.ok) / r.dt
		out['A_single_20k_64B'] = '{"ok":${r.ok},"msg_s":${msg_s},"seconds":${r.dt}}'
		eprintln('A single 20k×64B: ok=${r.ok} msg/s=${msg_s:.1f}')
	}

	// B: 32 conn × 5k × 64 B
	{
		payload := []u8{len: 64, init: `x`}
		agg := run_many(addr, 32, 5000, payload)
		out['B_32conn_5k_each_64B'] = '{"total_msgs":${agg.total},"expected":${agg.expected},"success_rate":${agg.rate},"aggregate_msg_s":${agg.msg_s},"wall_seconds":${agg.wall}}'
		eprintln('B 32×5k×64B: total=${agg.total} agg msg/s=${agg.msg_s:.1f}')
	}

	// C: 100 conn × 1k × 64 B
	{
		payload := []u8{len: 64, init: `x`}
		agg := run_many(addr, 100, 1000, payload)
		out['C_100conn_1k_each_64B'] = '{"total_msgs":${agg.total},"expected":${agg.expected},"success_rate":${agg.rate},"aggregate_msg_s":${agg.msg_s},"wall_seconds":${agg.wall}}'
		eprintln('C 100×1k×64B: total=${agg.total} agg msg/s=${agg.msg_s:.1f}')
	}

	// D: single 5k × 1 KiB
	{
		payload := []u8{len: 1024, init: `y`}
		r := run_worker(addr, 5000, payload) or { panic(err) }
		msg_s := f64(r.ok) / r.dt
		mb_s := f64(r.ok) * 1024.0 * 2.0 / r.dt / 1e6
		out['D_single_5k_1KB'] = '{"ok":${r.ok},"msg_s":${msg_s},"MB_s_rx_tx":${mb_s},"seconds":${r.dt}}'
		eprintln('D single 5k×1KiB: ok=${r.ok} msg/s=${msg_s:.1f}')
	}

	// JSON object (hand-built; no json module dependency games)
	print('{')
	keys := ['A_single_20k_64B', 'B_32conn_5k_each_64B', 'C_100conn_1k_each_64B', 'D_single_5k_1KB']
	for i, k in keys {
		if i > 0 {
			print(',')
		}
		print('"${k}":${out[k]}')
	}
	println(',"client":"v-ws-load","addr":"${addr}"}')
}

struct Agg {
	total    int
	expected int
	rate     f64
	msg_s    f64
	wall     f64
}

fn run_many(addr string, clients int, n_msgs int, payload []u8) Agg {
	mut mu := sync.Mutex{}
	mut total := 0
	t0 := time.sys_mono_now()
	mut ch := chan WorkerResult{cap: clients}
	for _ in 0 .. clients {
		spawn fn [addr, n_msgs, payload, ch] () {
			r := run_worker(addr, n_msgs, payload) or {
				ch <- WorkerResult{
					ok: 0
					dt: 0
				}
				return
			}
			ch <- r
		}()
	}
	for _ in 0 .. clients {
		r := <-ch
		mu.lock()
		total += r.ok
		mu.unlock()
	}
	wall_ns := time.sys_mono_now() - t0
	wall := f64(wall_ns) / 1e9
	expected := clients * n_msgs
	rate := if expected > 0 { f64(total) / f64(expected) } else { 0.0 }
	msg_s := if wall > 0 { f64(total) / wall } else { 0.0 }
	return Agg{
		total:    total
		expected: expected
		rate:     rate
		msg_s:    msg_s
		wall:     wall
	}
}

fn run_worker(addr string, n_msgs int, payload []u8) !WorkerResult {
	mut s := open_ws(addr)!
	defer {
		close_ws(mut s)
	}
	t0 := time.sys_mono_now()
	mut ok := 0
	for _ in 0 .. n_msgs {
		write_frame(mut s, 0x1, payload)!
		op, data := read_frame(mut s)!
		if op == 0x1 && bytes_eq(data, payload) {
			ok++
		} else {
			break
		}
	}
	dt := f64(time.sys_mono_now() - t0) / 1e9
	return WorkerResult{
		ok: ok
		dt: dt
	}
}

fn open_ws(addr string) !&net.TcpConn {
	key_raw := rand.bytes(16)!
	key := base64.encode(key_raw)
	mut s := net.dial_tcp(addr)!
	s.set_read_timeout(30 * time.second)
	s.set_write_timeout(30 * time.second)
	req := 'GET /ws HTTP/1.1\r\nHost: ${addr}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n'
	write_all(mut s, req.bytes())!
	mut buf := []u8{}
	mut tmp := []u8{len: 1024}
	for {
		n := s.read(mut tmp) or { return error('handshake read: ${err}') }
		if n <= 0 {
			return error('eof during handshake')
		}
		buf << tmp[..n]
		if index_crlfcrlf(buf) >= 0 {
			break
		}
		if buf.len > 16 * 1024 {
			return error('handshake too large')
		}
	}
	text := buf.bytestr()
	if !text.contains('101') {
		return error('handshake not 101: ${text#[..80]}')
	}
	return s
}

fn close_ws(mut s net.TcpConn) {
	// close code 1000, masked
	payload := [u8(0x03), 0xe8] // 1000
	write_frame(mut s, 0x8, payload) or {}
	s.close() or {}
}

fn write_frame(mut s net.TcpConn, opcode u8, payload []u8) ! {
	mask := rand.bytes(4)!
	plen := payload.len
	mut hdr := []u8{}
	b0 := opcode | 0x80
	if plen < 126 {
		hdr = [b0, u8(0x80 | plen)]
	} else if plen <= 65535 {
		hdr = [b0, u8(0x80 | 126), u8(plen >> 8), u8(plen)]
	} else {
		return error('payload too large for bench client')
	}
	mut frame := []u8{len: hdr.len + 4 + plen}
	for i in 0 .. hdr.len {
		frame[i] = hdr[i]
	}
	frame[hdr.len] = mask[0]
	frame[hdr.len + 1] = mask[1]
	frame[hdr.len + 2] = mask[2]
	frame[hdr.len + 3] = mask[3]
	off := hdr.len + 4
	for i in 0 .. plen {
		frame[off + i] = payload[i] ^ mask[i & 3]
	}
	write_all(mut s, frame)!
}

fn read_frame(mut s net.TcpConn) !(u8, []u8) {
	mut h := []u8{len: 2}
	read_exact(mut s, mut h)!
	op := h[0] & 0x0f
	mut plen := int(h[1] & 0x7f)
	if plen == 126 {
		mut ext := []u8{len: 2}
		read_exact(mut s, mut ext)!
		plen = int(u16(ext[0]) << 8 | u16(ext[1]))
	} else if plen == 127 {
		mut ext := []u8{len: 8}
		read_exact(mut s, mut ext)!
		// only low 32 bits for practical sizes
		plen = int(u32(ext[4]) << 24 | u32(ext[5]) << 16 | u32(ext[6]) << 8 | u32(ext[7]))
	}
	if h[1] & 0x80 != 0 {
		mut m := []u8{len: 4}
		read_exact(mut s, mut m)!
	}
	mut body := []u8{len: plen}
	if plen > 0 {
		read_exact(mut s, mut body)!
	}
	return op, body
}

fn write_all(mut s net.TcpConn, data []u8) ! {
	mut off := 0
	for off < data.len {
		n := s.write(data[off..]) or { return err }
		if n <= 0 {
			return error('short write')
		}
		off += n
	}
}

fn read_exact(mut s net.TcpConn, mut buf []u8) ! {
	mut off := 0
	for off < buf.len {
		mut slice := unsafe { buf[off..] }
		n := s.read(mut slice) or { return err }
		if n <= 0 {
			return error('eof')
		}
		off += n
	}
}

fn index_crlfcrlf(buf []u8) int {
	if buf.len < 4 {
		return -1
	}
	limit := buf.len - 3
	for i in 0 .. limit {
		if buf[i] == `\r` && buf[i + 1] == `\n` && buf[i + 2] == `\r` && buf[i + 3] == `\n` {
			return i
		}
	}
	return -1
}

fn bytes_eq(a []u8, b []u8) bool {
	if a.len != b.len {
		return false
	}
	for i in 0 .. a.len {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
