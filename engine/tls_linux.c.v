module engine

import net.mbedtls

#include "@VMODROOT/engine/tls_linux.h"

fn C.psa_crypto_init() i32
fn C.mbedtls_ssl_close_notify(ssl &C.mbedtls_ssl_context) i32
fn C.mbedtls_ssl_check_pending(ssl &C.mbedtls_ssl_context) i32
fn C.mbedtls_ssl_set_user_data_p(ssl &C.mbedtls_ssl_context, p voidptr)
fn C.mbedtls_ssl_get_user_data_p(ssl &C.mbedtls_ssl_context) voidptr
fn C.viltrum_tls_conf(conf &C.mbedtls_ssl_config, cert_cb fn (&C.mbedtls_ssl_context) int, drbg &C.mbedtls_ctr_drbg_context, h2 int) i32
fn C.viltrum_tls_fresh(ssl &C.mbedtls_ssl_context) int
fn C.viltrum_tls_bio_init(b &C.viltrum_bio, fd &int, buf &u8, cap usize)
fn C.viltrum_tls_bind_bio(ssl &C.mbedtls_ssl_context, b &C.viltrum_bio)
fn C.viltrum_tls_check_pair(crt &C.mbedtls_x509_crt, key &C.mbedtls_pk_context, drbg &C.mbedtls_ctr_drbg_context) i32
fn C.viltrum_tls_load_key(key &C.mbedtls_pk_context, path &char, drbg &C.mbedtls_ctr_drbg_context) i32
fn C.viltrum_tls_seed(drbg &C.mbedtls_ctr_drbg_context, entropy &C.mbedtls_entropy_context) i32
fn C.viltrum_tls_file_id(path &char, out &C.viltrum_file_id) i32

@[typedef]
struct C.viltrum_bio {
mut:
	off     usize
	len     usize
	drained int
}

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
// read-ahead under a TLS session: a full record and the start of the next
const tls_read_ahead = 16 * 1024

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
	crt      C.mbedtls_x509_crt
	key      C.mbedtls_pk_context
	refs     int           // handshakes in progress that picked this pair
	own      bool          // hs13 can serve handshakes with it (hs13_load)
	rsa      C.viltrum_rsa // the key in hs13's signing form
	cert_msg []u8          // the TLS 1.3 Certificate message for the chain
}

fn (mut p CertPair) free() {
	C.mbedtls_x509_crt_free(&p.crt)
	C.mbedtls_pk_free(&p.key)
	C.viltrum_hs13_wipe(&p.rsa, sizeof(C.viltrum_rsa))
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
	h2        bool // ALPN offers h2 before http/1.1
}

// new_tls_server sets up a worker's TLS state and loads the pair. cold: startup.
fn new_tls_server(o TlsOptions, logs bool, h2 bool) !&TlsServer {
	mut s := &TlsServer{
		cert_file: o.cert_file
		key_file:  o.key_file
		logs:      logs
		h2:        h2
	}
	C.mbedtls_entropy_init(&s.entropy)
	C.mbedtls_ctr_drbg_init(&s.drbg)
	C.mbedtls_ssl_config_init(&s.conf)
	if C.viltrum_tls_seed(&s.drbg, &s.entropy) != 0 {
		return error('viltrum: TLS random generator failed to seed')
	}
	ret := C.viltrum_tls_conf(&s.conf, tls_pick_cert, &s.drbg, if h2 { 1 } else { 0 })
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
	p.hs13_load(mut s)
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
// Conn serves TLS and kept with it. Its buffers are the worker's, lent while it uses
// them, and mbedtls' context is set up only for a session mbedtls has (mbed_start):
// hs13 serves most handshakes and tls13 their records, without it.
@[heap]
struct TlsConn {
mut:
	ssl         C.mbedtls_ssl_context
	mbed        bool // ssl is set up, with the buffers that takes
	bio         C.viltrum_bio
	inbuf       []u8 // bio read-ahead, lent for the handshake (and an mbedtls session)
	srv         &TlsServer = unsafe { nil }
	pair        &CertPair  = unsafe { nil } // picked for the handshake in progress
	handshaking bool
	wlen        int // length of a record mbedtls holds half written; the retry must pass it again
	fd          &int = unsafe { nil } // the Conn's fd
	secrets     C.viltrum_tls_secrets // TLS 1.3 traffic secrets, as the handshake exports them
	fast        bool                  // records are done by tls13 (TLS 1.3 with AES-GCM), not mbedtls
	r13         Tls13
	hs13        int // hs13_hello, hs13_flight, hs13_finished, or hs13_off once mbedtls has it
	hello       C.viltrum_hs13_hello
	keys        C.viltrum_hs13_keys
	hs_out      []u8 // hs13's server flight
	hs_off      int  // bytes of it sent
	h2          bool // ALPN chose h2: the connection speaks HTTP/2 once the handshake is done
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

// tls_start attaches a TLS session for srv to c and begins the handshake, with a
// read-ahead from w (Worker.tls_settle takes it back).
fn (mut c Conn) tls_start(srv &TlsServer, mut w Worker) bool {
	if isnil(c.tls_keep) {
		mut nt := &TlsConn{} // cold: once per pooled Conn
		C.mbedtls_ssl_init(&nt.ssl)
		c.tls_keep = nt
	}
	mut t := c.tls_keep
	t.srv = srv
	if t.inbuf.cap == 0 {
		t.inbuf = w.tls_inbuf()
	}
	C.viltrum_tls_bio_init(&t.bio, &c.fd, t.inbuf.data, usize(t.inbuf.len))
	t.fd = &c.fd
	t.fast = false
	t.h2 = false
	t.hello.h2 = if srv.h2 { 1 } else { 0 }
	t.handshaking = true
	t.wlen = 0
	t.hs13 = if hs13_supported { hs13_hello } else { hs13_off }
	t.hs_off = 0
	unsafe {
		t.hs_out.len = 0
	}
	// without hs13, mbedtls has the session from the start
	if t.hs13 == hs13_off && !t.mbed_start() {
		return false
	}
	c.tls = t
	return true
}

// mbed_start hands the session to mbedtls: its context is set up now, with the record
// buffers and handshake state that takes, and freed once the session no longer needs
// it (mbed_end). The bio keeps what it has read ahead.
fn (mut t TlsConn) mbed_start() bool {
	ret := C.mbedtls_ssl_setup(&t.ssl, &t.srv.conf)
	if ret != 0 {
		$if viltrum_debug ? {
			eprintln('[viltrum] TLS setup failed: -0x${-ret:04x}') // cold: debug builds only
		}
		C.mbedtls_ssl_free(&t.ssl)
		C.mbedtls_ssl_init(&t.ssl)
		return false
	}
	t.mbed = true
	C.mbedtls_ssl_set_user_data_p(&t.ssl, t)
	C.viltrum_tls_bind_bio(&t.ssl, &t.bio)
	C.viltrum_tls_set_export(&t.ssl, &t.secrets)
	return true
}

// mbed_end frees mbedtls' context, if it has one.
fn (mut t TlsConn) mbed_end() {
	if t.mbed {
		C.mbedtls_ssl_free(&t.ssl)
		C.mbedtls_ssl_init(&t.ssl)
		t.mbed = false
	}
}

// handshake advances the handshake: hs_done, hs_want_read, hs_want_write or hs_failed.
// hs13 tries first; a ClientHello it does not serve goes to mbedtls as it arrived.
fn (mut t TlsConn) handshake() int {
	if t.hs13 != hs13_off {
		r := t.hs13_step()
		$if viltrum_debug ? {
			what := if r == hs_done {
				'done'
			} else if r == hs13_defer {
				'to mbedtls'
			} else if r == hs_failed {
				'failed'
			} else {
				''
			}
			if what != '' {
				eprintln('[viltrum] hs13: ' + what) // cold: debug builds only
			}
		}
		if r != hs13_defer {
			return r
		}
		t.hs13 = hs13_off
		if !t.mbed_start() {
			return hs_failed
		}
	}
	ret := C.mbedtls_ssl_handshake(&t.ssl)
	if ret == 0 {
		t.handshaking = false
		p := &u8(C.mbedtls_ssl_get_alpn_protocol(&t.ssl))
		t.h2 = !isnil(p) && unsafe { p[0] == `h` && p[1] == `2` && p[2] == 0 }
		t.release()
		t.go_fast()
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
	if t.fast {
		return t.read13(*t.fd, buf, n)
	}
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
	if t.fast {
		return t.write13(*t.fd, buf, n)
	}
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

// fresh reports a handshake that has not processed a ClientHello yet. Its next step
// is the expensive one: the key exchange and the certificate signature, together
// milliseconds of CPU with an RSA key.
fn (t &TlsConn) fresh() bool {
	if t.hs13 == hs13_flight || t.hs13 == hs13_finished {
		return false
	}
	if !t.mbed {
		return true // hs13 has not read the hello yet
	}
	return C.viltrum_tls_fresh(&t.ssl) != 0
}

// pending reports input that epoll cannot see: in mbedtls or in the read-ahead.
fn (t &TlsConn) pending() bool {
	if t.fast {
		return t.pending13()
	}
	return t.bio.off < t.bio.len || (t.mbed && C.mbedtls_ssl_check_pending(&t.ssl) != 0)
}

// readable notes that epoll reported the socket readable, so the read-ahead may
// call recv again.
fn (mut t TlsConn) readable() {
	t.bio.drained = 0
	t.r13.drained = false
}

// close sends close_notify (one non-blocking attempt) and drops the pair reference.
fn (mut t TlsConn) close() {
	if t.fast {
		t.close13(*t.fd)
	} else if !t.handshaking && t.mbed {
		C.mbedtls_ssl_close_notify(&t.ssl)
	}
	t.mbed_end()
	t.release()
	t.handshaking = false
	if t.hs13 != hs13_off {
		// a handshake hs13 did not finish: its keys are still in the record state
		C.viltrum_hs13_wipe(&t.keys, sizeof(C.viltrum_hs13_keys))
		if !isnil(t.r13.rx) {
			C.viltrum_gcm_wipe(t.r13.rx)
			C.viltrum_gcm_wipe(t.r13.tx)
		}
		C.viltrum_tls_wipe(&t.r13.tx_iv[0], 12)
		t.hs13 = hs13_off
	}
}
