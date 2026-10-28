module engine

// The TLS 1.3 record layer for AES-GCM sessions, taken over from mbedtls once the
// handshake is done (TlsConn.go_fast). mbedtls sealed and opened records 16 bytes at
// a time through its cipher layer: two thirds of the CPU of a 10 KB TLS echo.
// Records here go through aesgcm.h in one call each, read ahead into one buffer and
// opened in place. The handshake, TLS 1.2 and ChaCha20 sessions stay on mbedtls.
//
// RFC 8446 section 5: a record is a 5-byte header (type 23, legacy version 0x0303,
// length) and AEAD ciphertext of the content, its real type and zero padding. The
// nonce is the write IV XOR the record's sequence number; the header is the AAD.
// After the handshake only application data, alerts and KeyUpdate may arrive.

@[typedef]
struct C.viltrum_tls_secrets {
mut:
	client [48]u8
	server [48]u8
	len    u64
	have   int
}

fn C.viltrum_tls_set_export(ssl &C.mbedtls_ssl_context, s &C.viltrum_tls_secrets)
fn C.viltrum_tls_is13(ssl &C.mbedtls_ssl_context) int
fn C.viltrum_tls13_expand(sha384 int, secret &u8, secret_len u64, label &char, out &u8, out_len u64) int
fn C.viltrum_tls_wipe(p voidptr, n u64)
fn C.mbedtls_ssl_get_ciphersuite_id_from_ssl(ssl &C.mbedtls_ssl_context) int

const tls13_aes128 = 0x1301 // TLS_AES_128_GCM_SHA256
const tls13_aes256 = 0x1302 // TLS_AES_256_GCM_SHA384
const tls13_max_plain = 16384 // RFC 8446 5.1
const tls13_max_record = 16384 + 256 // ciphertext limit, 5.2
const tls13_in_cap = 2 * (5 + tls13_max_record) // a full record and most of the next
const tls13_out_cap = 5 + tls13_max_plain + 1 + 16
// Records sealed under one key before we send a KeyUpdate: AES-GCM keeps its
// margin for 2^24.5 full records (RFC 8446 5.5), and the nonce must never repeat.
const tls13_rekey_at = u64(1) << 24
// KeyUpdates accepted from the peer on one connection.
const tls13_max_key_updates = 1024

const ct_alert = u8(21)
const ct_handshake = u8(22)
const ct_app = u8(23)

// Tls13 is the state of a session whose records tls13 does.
struct Tls13 {
mut:
	rx      &C.viltrum_gcm = unsafe { nil } // the client's write key: we open with it
	tx      &C.viltrum_gcm = unsafe { nil }
	rx_iv   [12]u8
	tx_iv   [12]u8
	rx_seq  u64
	tx_seq  u64
	rx_sec  [48]u8 // traffic secrets, kept for KeyUpdate
	tx_sec  [48]u8
	sec_len int
	sha384  bool
	inb     []u8 // ciphertext read ahead; records are opened in place
	in_off  int  // next unread record
	pt_off  int  // the opened record's content not yet handed out runs from pt_off to pt_end
	pt_end  int
	out     []u8 // one sealed record on its way out
	out_off int  // bytes of out already sent
	out_pt  int  // content bytes of the caller's that out carries
	drained bool // the last recv came back short: the socket is empty until epoll says
	ku_owed bool // the peer asked for a KeyUpdate; ours goes before the next record
	ku_seen int  // KeyUpdates the peer sent: each costs a key schedule, so capped
}

// go_fast moves a finished TLS 1.3 AES-GCM handshake's records here; anything else,
// or a CPU without AES-NI and PCLMUL, stays on mbedtls.
fn (mut t TlsConn) go_fast() {
	t.fast = false
	if !aesgcm_supported || C.viltrum_tls_is13(&t.ssl) == 0 {
		return
	}
	suite := C.mbedtls_ssl_get_ciphersuite_id_from_ssl(&t.ssl)
	if suite != tls13_aes128 && suite != tls13_aes256 {
		return
	}
	sha384 := suite == tls13_aes256
	want := if sha384 { 48 } else { 32 }
	// mbedtls has handed nothing on yet; anything it held would be lost
	if t.secrets.have != 3 || int(t.secrets.len) != want || C.mbedtls_ssl_check_pending(&t.ssl) != 0 {
		return
	}
	mut r := &t.r13
	if !r.alloc() {
		return
	}
	r.sha384 = sha384
	r.sec_len = want
	unsafe {
		vmemcpy(&r.rx_sec[0], &t.secrets.client[0], want)
		vmemcpy(&r.tx_sec[0], &t.secrets.server[0], want)
	}
	C.viltrum_tls_wipe(&t.secrets, sizeof(C.viltrum_tls_secrets))
	if !r.derive(true) || !r.derive(false) {
		return
	}
	r.start()
	// whatever the read-ahead holds past the handshake is the first records
	if t.bio.off < t.bio.len {
		n := int(t.bio.len - t.bio.off)
		unsafe {
			vmemcpy(r.inb.data, &u8(t.inbuf.data) + t.bio.off, n)
			r.inb.len = n
		}
		t.bio.off = t.bio.len
	}
	t.fast = true
	t.mbed_end() // the records are tls13's from here
}

// alloc sets up the key states, once per pooled TlsConn. The buffers are the worker's,
// lent while the connection uses them (Worker.tls_lend).
fn (mut r Tls13) alloc() bool {
	if isnil(r.rx) {
		r.rx = C.viltrum_gcm_new() // cold: once per pooled TlsConn
		r.tx = C.viltrum_gcm_new() // cold: once per pooled TlsConn
	}
	return !isnil(r.rx) && !isnil(r.tx) && r.inb.cap > 0 && r.out.cap > 0
}

// tls_lend lends t's record buffers, as Worker.lend does rbuf and wbuf: one for the
// ciphertext read ahead, one for a sealed record on its way out.
fn (mut w Worker) tls_lend(mut t TlsConn) {
	mut r := &t.r13
	if r.inb.cap == 0 {
		r.inb = if w.tin_pool.len > 0 {
			w.tin_pool.pop()
		} else {
			[]u8{cap: tls13_in_cap} // cold: past the most TLS connections ever busy at once
		}
	}
	if r.out.cap == 0 {
		r.out = if w.tout_pool.len > 0 {
			w.tout_pool.pop()
		} else {
			[]u8{cap: tls13_out_cap} // cold: as above
		}
	}
}

// tls_settle takes back t's record buffers that are empty: everything read ahead
// opened and handed out, no record half sent. With all set the connection is
// closing, and they go back whatever they hold. The pushes are unsafe as in give_back.
fn (mut w Worker) tls_settle(mut t TlsConn, all bool) {
	mut r := &t.r13
	if r.inb.cap > 0 && (all || (r.in_off == r.inb.len && r.pt_off >= r.pt_end)) {
		unsafe {
			r.inb.len = 0
		}
		r.in_off = 0
		r.pt_off = 0
		r.pt_end = 0
		w.tin_pool << unsafe { r.inb } // cold: grows to the most TLS connections ever busy at once
		r.inb = []u8{}
	}
	if r.out.cap > 0 && (all || r.out.len == 0) {
		unsafe {
			r.out.len = 0
		}
		r.out_off = 0
		r.out_pt = 0
		w.tout_pool << unsafe { r.out } // cold: as above
		r.out = []u8{}
	}
	// the handshake's read-ahead, once a session no longer needs it: tls13 reads its
	// own records, and a closing one needs nothing
	if t.inbuf.cap > 0 && (all || (t.fast && !t.handshaking)) {
		unsafe {
			t.inbuf.len = 0
		}
		w.wpool << unsafe { t.inbuf } // cold: as above
		t.inbuf = []u8{}
	}
}

// tls_inbuf is a read-ahead for a handshake, from the write pool: its buffers are at
// least as large.
fn (mut w Worker) tls_inbuf() []u8 {
	mut b := if w.wpool.len > 0 {
		w.wpool.pop()
	} else {
		[]u8{cap: write_buf_size} // cold: past the most connections ever busy at once
	}
	unsafe {
		b.len = tls_read_ahead
	}
	return b
}

// start resets the record state for a session's first records.
fn (mut r Tls13) start() {
	r.rx_seq = 0
	r.tx_seq = 0
	unsafe {
		r.inb.len = 0
		r.out.len = 0
	}
	r.in_off = 0
	r.pt_off = 0
	r.pt_end = 0
	r.out_off = 0
	r.out_pt = 0
	r.drained = false
	r.ku_owed = false
	r.ku_seen = 0
}

// derive sets the key and IV of one direction from its traffic secret.
fn (mut r Tls13) derive(rx bool) bool {
	mut tkey := [32]u8{} // not `key`: ws_test.v has a const of that name
	klen := if r.sha384 { 32 } else { 16 }
	sec := if rx { &r.rx_sec[0] } else { &r.tx_sec[0] }
	iv := if rx { &r.rx_iv[0] } else { &r.tx_iv[0] }
	mut ok := C.viltrum_tls13_expand(int(r.sha384), sec, u64(r.sec_len), c'key', &tkey[0],
		u64(klen)) == 0
	ok = ok && C.viltrum_tls13_expand(int(r.sha384), sec, u64(r.sec_len), c'iv', iv, 12) == 0
	ok = ok && C.viltrum_gcm_init(if rx { r.rx } else { r.tx }, &tkey[0], klen) == 0
	C.viltrum_tls_wipe(&tkey[0], 32)
	return ok
}

// update moves one direction to its next traffic secret (KeyUpdate, RFC 8446 7.2).
fn (mut r Tls13) update(rx bool) bool {
	mut next := [48]u8{}
	sec := if rx { &r.rx_sec[0] } else { &r.tx_sec[0] }
	if C.viltrum_tls13_expand(int(r.sha384), sec, u64(r.sec_len), c'traffic upd', &next[0],
		u64(r.sec_len)) != 0 {
		return false
	}
	unsafe { vmemcpy(sec, &next[0], r.sec_len) }
	C.viltrum_tls_wipe(&next[0], 48)
	if rx {
		r.rx_seq = 0
	} else {
		r.tx_seq = 0
	}
	return r.derive(rx)
}

// nonce is iv XOR the sequence number, right-aligned (RFC 8446 5.3).
@[direct_array_access]
fn nonce(iv &u8, seq u64, mut out [12]u8) {
	for i in 0 .. 12 {
		out[i] = unsafe { iv[i] }
	}
	for i in 0 .. 8 {
		out[11 - i] ^= u8(seq >> (8 * i))
	}
}

// read13 is TlsConn.read for a fast session: content bytes read, 0 at the peer's
// close_notify or end of stream, -1 when nothing is available now, -2 on error.
fn (mut t TlsConn) read13(fd int, buf &u8, n int) int {
	mut r := &t.r13
	for {
		if r.pt_off < r.pt_end {
			k := if n < r.pt_end - r.pt_off { n } else { r.pt_end - r.pt_off }
			unsafe { vmemcpy(buf, &u8(r.inb.data) + r.pt_off, k) }
			r.pt_off += k
			return k
		}
		got := r.open_next()
		if got == 1 {
			continue
		}
		if got == -3 {
			return 0
		}
		if got < 0 {
			return -2
		}
		if r.drained {
			return -1
		}
		// the content of every opened record is out, so the rest can move down
		rest := r.inb.len - r.in_off
		if r.in_off > 0 {
			if rest > 0 {
				unsafe { C.memmove(r.inb.data, &u8(r.inb.data) + r.in_off, rest) }
			}
			unsafe {
				r.inb.len = rest
			}
			r.in_off = 0
			r.pt_off = 0
			r.pt_end = 0
		}
		room := r.inb.cap - r.inb.len
		if room == 0 {
			return -2 // cannot happen: a record is shorter than half the buffer
		}
		m := int(C.recv(fd, unsafe { &u8(r.inb.data) + r.inb.len }, room, 0))
		if m == 0 {
			return 0
		}
		if m < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK || C.errno == C.EINTR {
				r.drained = true
				return -1
			}
			return -2
		}
		r.drained = m < room
		unsafe {
			r.inb.len += m
		}
	}
	return -2
}

// open_next opens the next whole record in inb: 1 when it was handled (content now
// in pt_off..pt_end, or an alert or KeyUpdate taken care of), 0 when it has not all
// arrived, -3 at close_notify, -2 on anything the protocol forbids.
@[direct_array_access]
fn (mut r Tls13) open_next() int {
	avail := r.inb.len - r.in_off
	if avail < 5 {
		return 0
	}
	p := unsafe { &u8(r.inb.data) + r.in_off }
	length := int(u16(unsafe { p[3] }) << 8 | u16(unsafe { p[4] }))
	// only protected records after the handshake; past the limit is record_overflow
	if unsafe { p[0] } != ct_app || length > tls13_max_record || length < 17 {
		return -2
	}
	if avail < 5 + length {
		return 0
	}
	mut iv := [12]u8{}
	nonce(&r.rx_iv[0], r.rx_seq, mut iv)
	body := unsafe { p + 5 }
	clen := length - 16
	if C.viltrum_gcm_open(r.rx, &iv[0], p, 5, body, body, u64(clen), unsafe { body + clen }) != 0 {
		return -2 // bad_record_mac
	}
	r.rx_seq++
	start := r.in_off + 5
	r.in_off += 5 + length
	// the real type is the last non-zero byte; zeros after it are padding
	mut e := clen
	for e > 0 && unsafe { body[e - 1] } == 0 {
		e--
	}
	if e == 0 || e - 1 > tls13_max_plain {
		return -2
	}
	typ := unsafe { body[e - 1] }
	e--
	if typ == ct_app {
		r.pt_off = start
		r.pt_end = start + e
		return 1
	}
	if typ == ct_alert {
		// close_notify ends the stream; every other alert in TLS 1.3 is fatal
		return if e == 2 && unsafe { body[1] } == 0 { -3 } else { -2 }
	}
	if typ == ct_handshake {
		// KeyUpdate (type 24, one byte: update_requested) is the only handshake
		// message a client may send now
		if e != 5 || unsafe { body[0] } != 24 || unsafe { body[1] } != 0 || unsafe { body[2] } != 0
			|| unsafe { body[3] } != 1 || unsafe { body[4] } > 1 {
			return -2
		}
		// A peer rekeys once in 2^24 records; one that rekeys per record is making
		// this worker derive keys (HKDF, AES key expansion, GHASH powers) at 27
		// bytes a time, so it is cut off.
		r.ku_seen++
		if r.ku_seen > tls13_max_key_updates {
			return -2
		}
		if unsafe { body[4] } == 1 {
			r.ku_owed = true
		}
		return if r.update(true) { 1 } else { -2 }
	}
	return -2
}

// pending13 reports input epoll cannot see: content not yet handed out, or a whole
// record waiting in the read-ahead.
fn (t &TlsConn) pending13() bool {
	r := &t.r13
	if r.pt_off < r.pt_end {
		return true
	}
	avail := r.inb.len - r.in_off
	if avail < 5 {
		return false
	}
	p := unsafe { &u8(r.inb.data) + r.in_off }
	return avail >= 5 + int(u16(unsafe { p[3] }) << 8 | u16(unsafe { p[4] }))
}

// write13 is TlsConn.write for a fast session: content bytes taken, -1 when the
// socket is full (call again from the same offset once it is writable), -2 on error.
// One call seals at most one record, and a record that goes out in pieces is not
// counted as taken until its last byte is sent.
fn (mut t TlsConn) write13(fd int, buf &u8, n int) int {
	mut r := &t.r13
	if r.out_off < r.out.len {
		s := r.send(fd)
		if s != 1 {
			return s
		}
		taken := r.out_pt
		r.out_pt = 0
		if taken > 0 {
			return taken
		}
	}
	if r.ku_owed || r.tx_seq >= tls13_rekey_at {
		// our KeyUpdate (update_not_requested), under the old key, then the new one
		ku := [u8(24), 0, 0, 1, 0]!
		r.seal(&ku[0], 5, ct_handshake)
		r.ku_owed = false
		if !r.update(false) {
			return -2
		}
		s := r.send(fd)
		if s != 1 {
			return s
		}
	}
	k := if n > tls13_max_plain { tls13_max_plain } else { n }
	r.seal(buf, k, ct_app)
	r.out_pt = k
	s := r.send(fd)
	if s != 1 {
		return s
	}
	r.out_pt = 0
	return k
}

// seal makes out one record of n content bytes of type typ.
fn (mut r Tls13) seal(src &u8, n int, typ u8) {
	length := n + 1 + 16
	unsafe {
		mut p := &u8(r.out.data)
		p[0] = ct_app
		p[1] = 3
		p[2] = 3
		p[3] = u8(length >> 8)
		p[4] = u8(length)
		vmemcpy(p + 5, src, n)
		p[5 + n] = typ
		mut iv := [12]u8{}
		nonce(&r.tx_iv[0], r.tx_seq, mut iv)
		C.viltrum_gcm_seal(r.tx, &iv[0], p, 5, p + 5, p + 5, u64(n + 1), p + 5 + n + 1)
		r.out.len = 5 + length
	}
	r.tx_seq++
	r.out_off = 0
}

// send pushes out what is left of the sealed record: 1 when all of it is sent, -1
// when the socket is full, -2 on error.
fn (mut r Tls13) send(fd int) int {
	for r.out_off < r.out.len {
		m := int(C.send(fd, unsafe { &u8(r.out.data) + r.out_off }, r.out.len - r.out_off,
			C.MSG_NOSIGNAL))
		if m < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK || C.errno == C.EINTR {
				return -1
			}
			return -2
		}
		r.out_off += m
	}
	unsafe {
		r.out.len = 0
	}
	r.out_off = 0
	return 1
}

// close13 sends close_notify (one attempt, unless a record is still going out) and
// wipes the keys.
fn (mut t TlsConn) close13(fd int) {
	mut r := &t.r13
	if r.out_off >= r.out.len {
		alert := [u8(1), 0]! // warning, close_notify
		r.seal(&alert[0], 2, ct_alert)
		_ = r.send(fd)
	}
	C.viltrum_gcm_wipe(r.rx)
	C.viltrum_gcm_wipe(r.tx)
	C.viltrum_tls_wipe(&r.rx_sec[0], 48)
	C.viltrum_tls_wipe(&r.tx_sec[0], 48)
	C.viltrum_tls_wipe(&r.rx_iv[0], 12)
	C.viltrum_tls_wipe(&r.tx_iv[0], 12)
	t.fast = false
}
