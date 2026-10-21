module engine

import net.mbedtls

#include "@VMODROOT/engine/tls_linux.h"

fn C.psa_crypto_init() i32
fn C.mbedtls_ssl_close_notify(ssl &C.mbedtls_ssl_context) i32
fn C.mbedtls_ssl_check_pending(ssl &C.mbedtls_ssl_context) i32
fn C.mbedtls_ssl_set_user_data_p(ssl &C.mbedtls_ssl_context, p voidptr)
fn C.mbedtls_ssl_get_user_data_p(ssl &C.mbedtls_ssl_context) voidptr
fn C.viltrum_tls_conf(conf &C.mbedtls_ssl_config, cert_cb fn (&C.mbedtls_ssl_context) int, drbg &C.mbedtls_ctr_drbg_context) i32
fn C.viltrum_tls_reset(ssl &C.mbedtls_ssl_context) i32
fn C.viltrum_tls_set_bio(ssl &C.mbedtls_ssl_context, fd &int)
fn C.viltrum_tls_check_pair(crt &C.mbedtls_x509_crt, key &C.mbedtls_pk_context, drbg &C.mbedtls_ctr_drbg_context) i32
fn C.viltrum_tls_load_key(key &C.mbedtls_pk_context, path &char, drbg &C.mbedtls_ctr_drbg_context) i32
fn C.viltrum_tls_seed(drbg &C.mbedtls_ctr_drbg_context, entropy &C.mbedtls_entropy_context) i32
fn C.viltrum_tls_file_id(path &char, out &C.viltrum_file_id) i32

@[typedef]
struct C.viltrum_file_id {
mut:
	dev        u64
	ino        u64
	size       i64
	mtime_sec  i64
	mtime_nsec i64
}

// largest plaintext handed to one mbedtls_ssl_write: one TLS record
const tls_record_max = 16384

// handshake results
const hs_done = 1
const hs_want_read = 0
const hs_want_write = 2
const hs_failed = -1

// tls_init runs psa_crypto_init, which mbedtls 3.6 needs before a TLS 1.3 handshake;
// it is idempotent. Naming a net.mbedtls type keeps that module (its objects and its
// thread-safety setup) in the build. cold: startup.
fn tls_init() ! {
	_ = mbedtls.SSLConnectConfig{}
	if C.psa_crypto_init() != 0 {
		return error('viltrum: psa_crypto_init failed')
	}
}

// CertPair is a loaded certificate chain and its private key.
@[heap]
struct CertPair {
mut:
	crt  C.mbedtls_x509_crt
	key  C.mbedtls_pk_context
	refs int // handshakes in progress that picked this pair
}

fn (mut p CertPair) free() {
	C.mbedtls_x509_crt_free(&p.crt)
	C.mbedtls_pk_free(&p.key)
}

// TlsServer is one worker's state for one TLS listener. Nothing in it is shared
// with another thread, so the record path takes no lock.
@[heap]
struct TlsServer {
mut:
	conf      C.mbedtls_ssl_config
	entropy   C.mbedtls_entropy_context
	drbg      C.mbedtls_ctr_drbg_context
	cert_file string
	key_file  string
	pair      &CertPair = unsafe { nil }
	old       []&CertPair // replaced, freed once no handshake references them
	cert_id   C.viltrum_file_id
	key_id    C.viltrum_file_id
	bad_cert  C.viltrum_file_id // the last pair that failed to load, not retried until a file changes
	bad_key   C.viltrum_file_id
	logs      bool // one worker reports reload failures, not all of them
}

// new_tls_server sets up a worker's TLS state and loads the pair. cold: startup.
fn new_tls_server(o TlsOptions, logs bool) !&TlsServer {
	mut s := &TlsServer{
		cert_file: o.cert_file
		key_file:  o.key_file
		logs:      logs
	}
	C.mbedtls_entropy_init(&s.entropy)
	C.mbedtls_ctr_drbg_init(&s.drbg)
	C.mbedtls_ssl_config_init(&s.conf)
	if C.viltrum_tls_seed(&s.drbg, &s.entropy) != 0 {
		return error('viltrum: TLS random generator failed to seed')
	}
	ret := C.viltrum_tls_conf(&s.conf, tls_pick_cert, &s.drbg)
	if ret != 0 {
		return error('viltrum: TLS config failed (${ret})') // cold: startup
	}
	s.cert_id = file_id(s.cert_file)!
	s.key_id = file_id(s.key_file)!
	s.pair = s.load_pair()!
	return s
}

// free releases what new_tls_server set up. cold: the startup check only; workers
// keep theirs for the life of the process.
fn (mut s TlsServer) free() {
	if !isnil(s.pair) {
		s.pair.free()
	}
	C.mbedtls_ssl_config_free(&s.conf)
	C.mbedtls_ctr_drbg_free(&s.drbg)
	C.mbedtls_entropy_free(&s.entropy)
}

fn file_id(path string) !C.viltrum_file_id {
	mut id := C.viltrum_file_id{}
	if C.viltrum_tls_file_id(&char(path.str), &id) != 0 {
		return error('viltrum: cannot stat ${path}') // cold: startup and reload
	}
	return id
}

fn same_file(a C.viltrum_file_id, b C.viltrum_file_id) bool {
	return a.dev == b.dev && a.ino == b.ino && a.size == b.size && a.mtime_sec == b.mtime_sec
		&& a.mtime_nsec == b.mtime_nsec
}

// load_pair reads both files and checks that the key belongs to the certificate.
// cold: startup and reload.
fn (mut s TlsServer) load_pair() !&CertPair {
	mut p := &CertPair{}
	C.mbedtls_x509_crt_init(&p.crt)
	C.mbedtls_pk_init(&p.key)
	if C.mbedtls_x509_crt_parse_file(&p.crt, &char(s.cert_file.str)) != 0 {
		p.free()
		return error('viltrum: cannot load certificate ${s.cert_file}') // cold: startup and reload
	}
	if C.viltrum_tls_load_key(&p.key, &char(s.key_file.str), &s.drbg) != 0 {
		p.free()
		return error('viltrum: cannot load key ${s.key_file}') // cold: startup and reload
	}
	if C.viltrum_tls_check_pair(&p.crt, &p.key, &s.drbg) != 0 {
		p.free()
		return error('viltrum: ${s.key_file} is not the key of ${s.cert_file}') // cold: startup and reload
	}
	return p
}

// reload swaps in the files when either changed on disk since they were loaded. A
// pair that fails (missing, half written, or cert and key from different swaps)
// leaves the current one serving and is retried when the files change again.
// cold: once a second per worker, from sweep.
fn (mut s TlsServer) reload() {
	for i := s.old.len - 1; i >= 0; i-- {
		if s.old[i].refs == 0 {
			mut p := s.old[i]
			p.free()
			s.old.delete(i)
		}
	}
	cid := file_id(s.cert_file) or { return }
	kid := file_id(s.key_file) or { return }
	if (same_file(cid, s.cert_id) && same_file(kid, s.key_id))
		|| (same_file(cid, s.bad_cert) && same_file(kid, s.bad_key)) {
		return
	}
	p := s.load_pair() or {
		if s.logs {
			eprintln('[viltrum] TLS reload skipped, keeping the current certificate: ${err.msg()}') // cold: startup and reload
		}
		s.bad_cert = cid
		s.bad_key = kid
		return
	}
	s.old << s.pair
	s.pair = p
	s.cert_id = cid
	s.key_id = kid
}

// TlsConn is the TLS session of one Conn. It is created the first time a pooled
// Conn serves TLS and kept with it; later connections reset it, which reuses the
// buffers mbedtls allocated.
@[heap]
struct TlsConn {
mut:
	ssl         C.mbedtls_ssl_context
	srv         &TlsServer = unsafe { nil }
	pair        &CertPair  = unsafe { nil } // picked for the handshake in progress
	handshaking bool
	wlen        int // length of a record mbedtls holds half written; the retry must pass it again
}

// tls_pick_cert is mbedtls' certificate callback, run on every handshake: the
// worker's current pair, so a reloaded certificate applies to the next handshake.
fn tls_pick_cert(ssl &C.mbedtls_ssl_context) int {
	mut t := unsafe { &TlsConn(C.mbedtls_ssl_get_user_data_p(ssl)) }
	t.release()
	mut p := t.srv.pair
	p.refs++
	t.pair = p
	return int(C.mbedtls_ssl_set_hs_own_cert(ssl, &p.crt, &p.key))
}

fn (mut t TlsConn) release() {
	if !isnil(t.pair) {
		t.pair.refs--
		t.pair = unsafe { nil }
	}
}

// tls_start attaches a TLS session for srv to c and begins the handshake.
fn (mut c Conn) tls_start(srv &TlsServer) bool {
	if isnil(c.tls_keep) || voidptr(c.tls_keep.srv) != voidptr(srv) {
		if !isnil(c.tls_keep) {
			C.mbedtls_ssl_free(&c.tls_keep.ssl) // cold: the Conn moves to another TLS listener
		}
		mut t := &TlsConn{
			srv: srv
		} // cold: once per pooled Conn
		C.mbedtls_ssl_init(&t.ssl)
		ret := C.mbedtls_ssl_setup(&t.ssl, &srv.conf)
		if ret != 0 {
			$if viltrum_debug ? {
				eprintln('[viltrum] TLS setup failed: -0x${-ret:04x}') // cold: debug builds only
			}
			C.mbedtls_ssl_free(&t.ssl)
			c.tls_keep = unsafe { nil }
			return false
		}
		c.tls_keep = t
	} else if C.viltrum_tls_reset(&c.tls_keep.ssl) != 0 {
		return false
	}
	mut t := c.tls_keep
	C.mbedtls_ssl_set_user_data_p(&t.ssl, t)
	C.viltrum_tls_set_bio(&t.ssl, &c.fd)
	t.handshaking = true
	t.wlen = 0
	c.tls = t
	return true
}

// handshake advances the handshake: hs_done, hs_want_read, hs_want_write or hs_failed.
fn (mut t TlsConn) handshake() int {
	ret := C.mbedtls_ssl_handshake(&t.ssl)
	if ret == 0 {
		t.handshaking = false
		t.release()
		return hs_done
	}
	if ret == C.MBEDTLS_ERR_SSL_WANT_READ {
		return hs_want_read
	}
	if ret == C.MBEDTLS_ERR_SSL_WANT_WRITE {
		return hs_want_write
	}
	$if viltrum_debug ? {
		eprintln('[viltrum] TLS handshake failed: -0x${-ret:04x}') // cold: debug builds only
	}
	t.release()
	return hs_failed
}

// read is recv for a TLS connection: bytes read, 0 at the peer's close, -1 when
// nothing is available now, -2 on error.
fn (mut t TlsConn) read(buf &u8, n int) int {
	ret := int(C.mbedtls_ssl_read(&t.ssl, buf, usize(n)))
	if ret > 0 {
		return ret
	}
	if ret == 0 || ret == C.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY {
		return 0
	}
	if ret == C.MBEDTLS_ERR_SSL_WANT_READ || ret == C.MBEDTLS_ERR_SSL_WANT_WRITE {
		return -1
	}
	return -2
}

// write is send for a TLS connection: bytes taken, -1 when the socket is full (call
// again from the same offset once it is writable), -2 on error. One call writes at
// most one record.
fn (mut t TlsConn) write(buf &u8, n int) int {
	len := if t.wlen > 0 {
		t.wlen
	} else if n > tls_record_max {
		tls_record_max
	} else {
		n
	}
	ret := int(C.mbedtls_ssl_write(&t.ssl, buf, usize(len)))
	if ret > 0 {
		t.wlen = 0
		return ret
	}
	if ret == C.MBEDTLS_ERR_SSL_WANT_WRITE || ret == C.MBEDTLS_ERR_SSL_WANT_READ {
		t.wlen = len
		return -1
	}
	return -2
}

// pending reports input mbedtls holds that epoll cannot see.
fn (t &TlsConn) pending() bool {
	return C.mbedtls_ssl_check_pending(&t.ssl) != 0
}

// close sends close_notify (one non-blocking attempt) and drops the pair reference.
fn (mut t TlsConn) close() {
	if !t.handshaking {
		C.mbedtls_ssl_close_notify(&t.ssl)
	}
	t.release()
	t.handshaking = false
}
