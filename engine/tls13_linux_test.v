module engine

import net.mbedtls

// Two record layers keyed as the two ends of one session: a seals with the server
// secret and opens with the client one, b the other way round. Records move from a's
// out buffer into b's read-ahead, which is what the socket would do.

fn new_tls13(sha384 bool, n int) &Tls13 {
	return &Tls13{
		rx:      C.viltrum_gcm_new()
		tx:      C.viltrum_gcm_new()
		inb:     []u8{cap: tls13_in_cap}
		out:     []u8{cap: tls13_out_cap}
		sha384:  sha384
		sec_len: n
	}
}

fn pair(sha384 bool) (&Tls13, &Tls13) {
	_ = mbedtls.SSLConnectConfig{}
	n := if sha384 { 48 } else { 32 }
	mut a := new_tls13(sha384, n)
	mut b := new_tls13(sha384, n)
	for i in 0 .. n {
		a.tx_sec[i] = u8(i + 1)
		a.rx_sec[i] = u8(0xa0 + i)
		b.rx_sec[i] = u8(i + 1)
		b.tx_sec[i] = u8(0xa0 + i)
	}
	assert a.derive(true) && a.derive(false) && b.derive(true) && b.derive(false)
	return a, b
}

// pass moves a's sealed record into b's read-ahead.
fn pass(mut a Tls13, mut b Tls13) {
	unsafe { b.inb.push_many(a.out.data, a.out.len) }
	unsafe {
		a.out.len = 0
	}
}

fn content(b &Tls13) string {
	return b.inb[b.pt_off..b.pt_end].bytestr()
}

fn test_records_round_trip_both_suites() {
	if !aesgcm_supported {
		return
	}
	for sha384 in [false, true] {
		mut a, mut b := pair(sha384)
		for msg in ['hello', '', 'x'.repeat(tls13_max_plain)] {
			a.seal(msg.str, msg.len, ct_app)
			pass(mut a, mut b)
			assert b.pending13_raw()
			assert b.open_next() == 1
			assert content(b) == msg
			b.pt_off = b.pt_end
		}
		assert b.rx_seq == 3 && a.tx_seq == 3
	}
}

fn test_record_split_across_reads() {
	if !aesgcm_supported {
		return
	}
	mut a, mut b := pair(false)
	a.seal(c'split me', 8, ct_app)
	rec := a.out.clone()
	for i in 0 .. rec.len {
		b.inb << rec[i]
		if i < rec.len - 1 {
			assert b.open_next() == 0 && !b.pending13_raw()
		}
	}
	assert b.open_next() == 1 && content(b) == 'split me'
}

// seal_raw seals inner (content, type and any padding, as given) under a's key.
fn seal_raw(mut a Tls13, outer u8, inner []u8) {
	length := inner.len + 16
	unsafe {
		a.out.len = 5 + length
	}
	a.out[0] = outer
	a.out[1] = 3
	a.out[2] = 3
	a.out[3] = u8(length >> 8)
	a.out[4] = u8(length)
	for i, v in inner {
		a.out[5 + i] = v
	}
	mut iv := [12]u8{}
	nonce(&a.tx_iv[0], a.tx_seq, mut iv)
	p := unsafe { &u8(a.out.data) }
	C.viltrum_gcm_seal(a.tx, &iv[0], p, 5, unsafe { p + 5 }, unsafe { p + 5 }, u64(inner.len), unsafe {
		p + 5 + inner.len
	})
	a.tx_seq++
}

fn test_padding_alerts_and_bad_records() {
	if !aesgcm_supported {
		return
	}
	// padding: zeros after the real type
	mut a, mut b := pair(false)
	seal_raw(mut a, ct_app, [u8(`h`), `i`, ct_app, 0, 0, 0, 0])
	pass(mut a, mut b)
	assert b.open_next() == 1 && content(b) == 'hi'
	// all padding, no type: refused
	a, b = pair(false)
	seal_raw(mut a, ct_app, [u8(0), 0, 0])
	pass(mut a, mut b)
	assert b.open_next() == -2
	// close_notify ends the stream; another alert is fatal
	a, b = pair(false)
	seal_raw(mut a, ct_app, [u8(1), 0, ct_alert])
	pass(mut a, mut b)
	assert b.open_next() == -3
	a, b = pair(false)
	seal_raw(mut a, ct_app, [u8(2), 40, ct_alert])
	pass(mut a, mut b)
	assert b.open_next() == -2
	// a flipped bit in the header (the AAD), the ciphertext or the tag fails; type
	// 22 is refused before that, and a longer length waits for bytes that never come
	a, b = pair(false)
	a.seal(c'tamper', 6, ct_app)
	pass(mut a, mut b)
	b.inb[3] ^= 1
	assert b.open_next() == 0
	for at in [0, 1, 2, 4, 6, 20] {
		a, b = pair(false)
		a.seal(c'tamper', 6, ct_app)
		pass(mut a, mut b)
		b.inb[at] ^= 1
		assert b.open_next() == -2, 'byte ${at}'
	}
	// unprotected types after the handshake, and records past the limit
	for outer in [u8(20), 21, 22] {
		a, b = pair(false)
		seal_raw(mut a, outer, [u8(`x`), ct_app])
		pass(mut a, mut b)
		assert b.open_next() == -2
	}
	a, b = pair(false)
	b.inb << [u8(23), 3, 3, u8((tls13_max_record + 1) >> 8), u8(tls13_max_record + 1)]
	assert b.open_next() == -2
	// a replayed record has the wrong sequence number
	a, b = pair(false)
	a.seal(c'once', 4, ct_app)
	rec := a.out.clone()
	pass(mut a, mut b)
	assert b.open_next() == 1
	b.inb << rec
	assert b.open_next() == -2
}

fn test_key_update_both_ways() {
	if !aesgcm_supported {
		return
	}
	// a asks b to update too: its KeyUpdate goes out under the old key, then a switches
	mut a, mut b := pair(true)
	mut both := []u8{}
	seal_raw(mut a, ct_app, [u8(24), 0, 0, 1, 1, ct_handshake])
	assert a.update(false)
	a.seal(c'after', 5, ct_app) // seal appends: out holds both records now
	both << a.out
	b.inb << both
	assert b.open_next() == 1 && b.ku_owed && b.rx_seq == 0
	assert b.open_next() == 1 && content(b) == 'after'
	// b answers under its old key, then switches; a follows
	ku := [u8(24), 0, 0, 1, 0]!
	b.seal(&ku[0], 5, ct_handshake)
	assert b.update(false)
	pass(mut b, mut a)
	assert a.open_next() == 1 && !a.ku_owed
	b.seal(c'new key', 7, ct_app)
	pass(mut b, mut a)
	assert a.open_next() == 1 && content(a) == 'new key'
	// a malformed KeyUpdate is refused
	a, b = pair(false)
	seal_raw(mut a, ct_app, [u8(24), 0, 0, 1, 2, ct_handshake])
	pass(mut a, mut b)
	assert b.open_next() == -2
	a, b = pair(false)
	seal_raw(mut a, ct_app, [u8(4), 0, 0, 0, ct_handshake]) // NewSessionTicket from a client
	pass(mut a, mut b)
	assert b.open_next() == -2
}

// pending13_raw is pending13 for a bare Tls13.
fn (r &Tls13) pending13_raw() bool {
	mut t := TlsConn{}
	t.r13 = *r
	return t.pending13()
}

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int

// The sender rekeys on its own once 2^24 records went out under one key, and a peer
// that sends KeyUpdates without end is cut off.
fn test_key_update_limits() {
	if !aesgcm_supported {
		return
	}
	mut sv := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
	a, mut b := pair(false)
	mut t := TlsConn{}
	t.r13 = *a
	t.r13.tx_seq = tls13_rekey_at - 1
	b.rx_seq = tls13_rekey_at - 1
	assert t.write13(int(sv[0]), c'one', 3) == 3
	assert t.write13(int(sv[0]), c'two', 3) == 3 // at the limit: a KeyUpdate goes first
	assert t.r13.tx_seq == 1
	mut tmp := []u8{len: 4096}
	n := int(C.recv(int(sv[1]), tmp.data, tmp.len, 0))
	assert n > 0
	unsafe { b.inb.push_many(tmp.data, n) }
	assert b.open_next() == 1 && content(b) == 'one'
	assert b.open_next() == 1 && !b.ku_owed && b.rx_seq == 0 // the KeyUpdate, not requested back
	assert b.open_next() == 1 && content(b) == 'two'
	b.pt_off = b.pt_end
	// a large write goes out as several records in one send, and no more than out holds
	big := []u8{len: 5 * tls13_max_plain, init: u8(index)}
	assert t.write13(int(sv[0]), big.data, big.len) == tls13_out_records * tls13_max_plain
	mut got := []u8{}
	for got.len < tls13_out_records * tls13_max_plain {
		for !b.pending13_raw() {
			m := int(C.recv(int(sv[1]), tmp.data, tmp.len, 0))
			assert m > 0
			unsafe { b.inb.push_many(tmp.data, m) }
		}
		assert b.open_next() == 1
		got << b.inb[b.pt_off..b.pt_end]
		b.pt_off = b.pt_end
	}
	assert got == big[..tls13_out_records * tls13_max_plain]
	C.close(int(sv[0]))
	C.close(int(sv[1]))
	// a full socket: what was sealed counts as taken, and waits in out until push
	mut fds := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &fds[0]) == 0
	small := i32(4096)
	C.setsockopt(int(fds[0]), C.SOL_SOCKET, C.SO_SNDBUF, &small, sizeof(i32))
	C.fcntl(int(fds[0]), C.F_SETFL, C.O_NONBLOCK)
	a3, mut b3 := pair(false)
	mut t3 := TlsConn{
		fast: true
	}
	t3.r13 = *a3
	fd3 := int(fds[0])
	t3.fd = &fd3
	sent := t3.write13(fd3, big.data, big.len)
	assert sent == tls13_out_records * tls13_max_plain
	assert t3.out_pending()
	mut got3 := []u8{}
	for got3.len < sent {
		if t3.out_pending() {
			assert t3.push() != -2
		}
		m := int(C.recv(int(fds[1]), tmp.data, tmp.len, C.MSG_DONTWAIT))
		if m > 0 {
			unsafe { b3.inb.push_many(tmp.data, m) }
		}
		for b3.pending13_raw() {
			assert b3.open_next() == 1
			got3 << b3.inb[b3.pt_off..b3.pt_end]
			b3.pt_off = b3.pt_end
		}
	}
	assert !t3.out_pending() && got3 == big[..sent]
	C.close(int(fds[0]))
	C.close(int(fds[1]))
	// a peer that keeps asking
	mut a2, mut b2 := pair(false)
	for i in 0 .. tls13_max_key_updates {
		seal_raw(mut a2, ct_app, [u8(24), 0, 0, 1, 0, ct_handshake])
		pass(mut a2, mut b2)
		assert b2.open_next() == 1, 'update ${i}'
		assert a2.update(false)
	}
	seal_raw(mut a2, ct_app, [u8(24), 0, 0, 1, 0, ct_handshake])
	pass(mut a2, mut b2)
	assert b2.open_next() == -2
}
