module engine

// The TLS 1.3 server handshake viltrum does itself (hs13.h), and how a connection
// moves between it and mbedtls. A TLS connection starts here: its ClientHello is
// read into the BIO read-ahead without consuming it, and when hs13 does not serve
// that hello (TLS 1.2, no X25519 share, an ECDSA certificate, ...) mbedtls takes over
// with the bytes where they were. When it does, mbedtls is never called for the
// connection: hs13 sends the server flight, opens the client's Finished, and hands
// the session to tls13's record layer with the application traffic secrets.

#include "@VMODROOT/engine/hs13.h"

@[typedef]
struct C.viltrum_hs13_hello {
	share          [32]u8
	session_id_len u64
	alpn           int
	h2             int
}

@[typedef]
struct C.viltrum_hs13_keys {
	c_key [16]u8
	c_iv  [12]u8
	c_ap  [32]u8
	s_ap  [32]u8
	s_iv  [12]u8
	s_seq u64
}

@[typedef]
struct C.viltrum_rsa {
	ok int
}

fn C.viltrum_hs13_supported() int
fn C.viltrum_hs13_parse(msg &u8, len u64, h &C.viltrum_hs13_hello) int
fn C.viltrum_hs13_flight(ch &u8, ch_len u64, h &C.viltrum_hs13_hello, cert &u8, cert_len u64, key &C.viltrum_rsa, drbg &C.mbedtls_ctr_drbg_context, tx &C.viltrum_gcm, out &u8, cap u64, out_len &u64, keys &C.viltrum_hs13_keys) int
fn C.viltrum_hs13_finished_ok(msg &u8, len u64, keys &C.viltrum_hs13_keys) int
fn C.viltrum_hs13_cert_msg(crt &C.mbedtls_x509_crt, out &u8, cap u64) u64
fn C.viltrum_hs13_wipe(p voidptr, n u64)
fn C.viltrum_rsa_load(key &C.viltrum_rsa, pk &C.mbedtls_pk_context, drbg &C.mbedtls_ctr_drbg_context) int

// hs13_supported is whether this build and CPU can run hs13 (AES-NI and PCLMUL for
// the records, 128-bit integers for X25519 and RSA).
const hs13_supported = C.viltrum_hs13_supported() != 0

// TlsConn.hs13 states
const hs13_hello = 0 // reading the ClientHello
const hs13_flight = 1 // the server flight is going out
const hs13_finished = 2 // waiting for the client's Finished
const hs13_off = -1 // mbedtls has the handshake

// hs13_defer: hs13 does not serve this ClientHello; mbedtls does
const hs13_defer = 3

// fatal alerts hs13 sends before it closes (RFC 8446 6.2)
const alert_unexpected_message = u8(10)
const alert_bad_record_mac = u8(20)
const alert_illegal_parameter = u8(47)
const alert_decrypt_error = u8(51)
const alert_internal_error = u8(80)

const tls_ct_ccs = u8(20)

// hs13_load prepares a pair for hs13: the key in signing form and the Certificate
// message. A pair hs13 cannot use (not RSA, an unusual size) keeps p.own false, and
// its handshakes stay on mbedtls. cold: certificate load.
fn (mut p CertPair) hs13_load(mut s TlsServer) {
	p.own = false
	if !hs13_supported || C.viltrum_rsa_load(&p.rsa, &p.key, &s.drbg) != 0 {
		return
	}
	need := C.viltrum_hs13_cert_msg(&p.crt, unsafe { nil }, 0)
	p.cert_msg = []u8{len: int(need)}
	if C.viltrum_hs13_cert_msg(&p.crt, p.cert_msg.data, need) != need {
		return
	}
	p.own = true
}

// hs13_step advances an hs13 handshake: hs_done, hs_want_read, hs_want_write,
// hs_failed, or hs13_defer to hand the connection to mbedtls.
fn (mut t TlsConn) hs13_step() int {
	if t.hs13 == hs13_hello {
		r := t.hs13_hello()
		if r != hs_done {
			return r
		}
	}
	if t.hs13 == hs13_flight {
		for t.hs_off < t.hs_out.len {
			m := int(C.send(*t.fd, unsafe { &u8(t.hs_out.data) + t.hs_off },
				t.hs_out.len - t.hs_off, C.MSG_NOSIGNAL))
			if m < 0 {
				if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK || C.errno == C.EINTR {
					return hs_want_write
				}
				return hs_failed
			}
			t.hs_off += m
		}
		t.hs13 = hs13_finished
	}
	return t.hs13_finished()
}

// hs13_hello reads the ClientHello and, when hs13 serves it, builds the server
// flight: hs_done when the flight is ready to go out.
fn (mut t TlsConn) hs13_hello() int {
	mut b := &t.bio
	for {
		have := int(b.len)
		if have >= 5 {
			buf := unsafe { &u8(t.inbuf.data) }
			rec_len := int(u16(unsafe { buf[3] }) << 8 | u16(unsafe { buf[4] }))
			// not a handshake record, or past what a record may carry: mbedtls says so
			if unsafe { buf[0] } != ct_handshake || rec_len > tls13_max_plain {
				return hs13_defer
			}
			if have >= 5 + rec_len {
				return t.hs13_answer(rec_len)
			}
		}
		if b.len == u64(t.inbuf.len) {
			return hs13_defer // a hello larger than the read-ahead: mbedtls reassembles it
		}
		if b.drained != 0 {
			return hs_want_read
		}
		room := t.inbuf.len - int(b.len)
		m := int(C.recv(*t.fd, unsafe { &u8(t.inbuf.data) + b.len }, room, 0))
		if m == 0 {
			return hs_failed
		}
		if m < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK || C.errno == C.EINTR {
				b.drained = 1
				return hs_want_read
			}
			return hs_failed
		}
		b.len += u64(m)
		if m < room {
			b.drained = 1
		}
	}
	return hs_failed
}

// hs13_answer decides on the ClientHello in the first record (rec_len bytes after
// the header) and builds the server flight when hs13 serves it.
fn (mut t TlsConn) hs13_answer(rec_len int) int {
	buf := unsafe { &u8(t.inbuf.data) }
	if rec_len < 4 {
		return hs13_defer
	}
	msg := unsafe { buf + 5 }
	msg_len := 4 +
		int(u32(unsafe { msg[1] }) << 16 | u32(unsafe { msg[2] }) << 8 | u32(unsafe { msg[3] }))
	// split across records, or sharing its record with more: mbedtls reassembles
	if msg_len != rec_len {
		return hs13_defer
	}
	ok := C.viltrum_hs13_parse(msg, u64(msg_len), &t.hello)
	if ok < 0 {
		t.hs13_alert(alert_illegal_parameter)
		return hs_failed
	}
	mut p := t.srv.pair
	if ok == 0 || !p.own || !t.r13.alloc() {
		return hs13_defer
	}
	// the flight: the certificate chain and about a kilobyte, in records of 16 KB
	need := p.cert_msg.len + 1024 + 22 * (p.cert_msg.len / tls13_max_plain + 4)
	if t.hs_out.cap < need {
		t.hs_out = []u8{cap: need} // cold: grows to the largest certificate chain
	}
	mut out_len := u64(0)
	if C.viltrum_hs13_flight(msg, u64(msg_len), &t.hello, p.cert_msg.data, u64(p.cert_msg.len),
		&p.rsa, &t.srv.drbg, t.r13.tx, t.hs_out.data, u64(t.hs_out.cap), &out_len, &t.keys) != 0 {
		t.hs13_alert(alert_internal_error)
		return hs_failed
	}
	unsafe {
		t.hs_out.len = int(out_len)
	}
	t.hs_off = 0
	// the hello is hs13's: mbedtls never reads it. Anything after it is the client's
	// next records, read under tls13's buffer from now on.
	mut r := &t.r13
	r.start()
	rest := int(t.bio.len) - 5 - rec_len
	if rest > 0 {
		unsafe {
			vmemcpy(r.inb.data, buf + 5 + rec_len, rest)
			r.inb.len = rest
		}
	}
	t.bio.off = t.bio.len
	// until the switch to the application keys, tx seals under the server handshake key
	unsafe { vmemcpy(&r.tx_iv[0], &t.keys.s_iv[0], 12) }
	r.tx_seq = t.keys.s_seq
	if C.viltrum_gcm_init(r.rx, &t.keys.c_key[0], 16) != 0 {
		return hs_failed
	}
	t.hs13 = hs13_flight
	return hs_done
}

// hs13_finished reads the client's records up to its Finished: a change_cipher_spec
// may come first (middlebox compatibility), then the Finished under the client's
// handshake key. Once it checks out the session moves to tls13 with the application
// keys; any records after it are the client's first application data.
fn (mut t TlsConn) hs13_finished() int {
	mut r := &t.r13
	for {
		avail := r.inb.len - r.in_off
		if avail >= 5 {
			p := unsafe { &u8(r.inb.data) + r.in_off }
			typ := unsafe { p[0] }
			length := int(u16(unsafe { p[3] }) << 8 | u16(unsafe { p[4] }))
			if length > tls13_max_record {
				return hs_failed
			}
			if avail >= 5 + length {
				if typ == tls_ct_ccs {
					if length != 1 || unsafe { p[5] } != 1 {
						return hs_failed
					}
					r.in_off += 6
					continue
				}
				if typ == ct_alert {
					return hs_failed // the client gave up: nothing to say back
				}
				if typ != ct_app || length < 17 {
					t.hs13_sealed_alert(alert_unexpected_message)
					return hs_failed
				}
				return t.hs13_open_finished(p, length)
			}
		}
		if r.in_off > 0 {
			rest := r.inb.len - r.in_off
			if rest > 0 {
				unsafe { C.memmove(r.inb.data, &u8(r.inb.data) + r.in_off, rest) }
			}
			unsafe {
				r.inb.len = rest
			}
			r.in_off = 0
		}
		if r.drained {
			return hs_want_read
		}
		room := r.inb.cap - r.inb.len
		m := int(C.recv(*t.fd, unsafe { &u8(r.inb.data) + r.inb.len }, room, 0))
		if m == 0 {
			return hs_failed
		}
		if m < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK || C.errno == C.EINTR {
				r.drained = true
				return hs_want_read
			}
			return hs_failed
		}
		r.drained = m < room
		unsafe {
			r.inb.len += m
		}
	}
	return hs_failed
}

// hs13_open_finished opens the record at p (length bytes after the header), which
// must hold the client's Finished, and switches to the application keys.
fn (mut t TlsConn) hs13_open_finished(p &u8, length int) int {
	mut r := &t.r13
	mut iv := [12]u8{}
	nonce(&t.keys.c_iv[0], 0, mut iv)
	body := unsafe { p + 5 }
	clen := length - 16
	if C.viltrum_gcm_open(r.rx, &iv[0], p, 5, body, body, u64(clen), unsafe { body + clen }) != 0 {
		t.hs13_sealed_alert(alert_bad_record_mac)
		return hs_failed
	}
	mut e := clen
	for e > 0 && unsafe { body[e - 1] } == 0 {
		e--
	}
	// one handshake message, the Finished, and nothing else in the record
	if e == 0 || unsafe { body[e - 1] } != ct_handshake
		|| C.viltrum_hs13_finished_ok(body, u64(e - 1), &t.keys) == 0 {
		// a Finished split over two records lands here too: no client known does that
		t.hs13_sealed_alert(alert_decrypt_error)
		return hs_failed
	}
	r.in_off += 5 + length
	r.pt_off = r.in_off
	r.pt_end = r.in_off
	r.sha384 = false
	r.sec_len = 32
	unsafe {
		vmemcpy(&r.rx_sec[0], &t.keys.c_ap[0], 32)
		vmemcpy(&r.tx_sec[0], &t.keys.s_ap[0], 32)
	}
	C.viltrum_hs13_wipe(&t.keys, sizeof(C.viltrum_hs13_keys))
	if !r.derive(true) || !r.derive(false) {
		return hs_failed
	}
	r.rx_seq = 0
	r.tx_seq = 0
	t.fast = true
	t.handshaking = false
	t.h2 = t.hello.alpn == 2
	t.hs13 = hs13_off
	return hs_done
}

// hs13_alert sends a fatal alert in the clear, as one try: the hello was refused
// before any key existed.
fn (mut t TlsConn) hs13_alert(desc u8) {
	rec := [u8(ct_alert), 3, 3, 0, 2, 2, desc]!
	_ = C.send(*t.fd, &rec[0], 7, C.MSG_NOSIGNAL)
}

// hs13_sealed_alert sends a fatal alert under the server handshake key, as one try:
// the client has the flight, so it reads records under that key.
fn (mut t TlsConn) hs13_sealed_alert(desc u8) {
	mut r := &t.r13
	if r.out_off < r.out.len {
		return
	}
	alert := [u8(2), desc]!
	r.seal(&alert[0], 2, ct_alert)
	_ = r.send(*t.fd)
}
