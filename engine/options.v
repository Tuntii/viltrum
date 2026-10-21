module engine

import sync.stdatomic
import time
import viltrum.http1

pub struct Options {
pub:
	// workers is the number of event loops; 0 means VILTRUM_WORKERS, else the CPUs
	// in the process affinity mask.
	workers       int
	limits        http1.Limits
	read_timeout  time.Duration = 30 * time.second // from a request's first byte to its last
	write_timeout time.Duration = 30 * time.second // while output is pending
	idle_timeout  time.Duration = 60 * time.second // between keep-alive requests
	max_conns     int // 0 = unlimited; excess connections get 503 and are closed
	// max_pending pauses pipelined processing while this much output waits to be sent.
	max_pending    int  = 1024 * 1024
	send_date      bool = true
	server_header  string
	require_host   bool  = true
	handle_signals bool  = true
	stop           &Stop = unsafe { nil } // stop a server without signals (tests, embedding)
}

// TlsOptions names the PEM files a TLS listener serves. Both are read again when
// they change on disk (checked once a second); a pair that fails to load is skipped
// and the last good one stays in use.
pub struct TlsOptions {
pub:
	cert_file string // certificate chain, leaf first
	key_file  string // private key, unencrypted
}

// Listener is one address to serve; with tls set it speaks HTTPS.
pub struct Listener {
pub:
	addr string
	tls  ?TlsOptions
}

// Stop asks a running server to shut down; workers notice within a second.
@[heap]
pub struct Stop {
mut:
	flag u64
}

pub fn new_stop() &Stop {
	return &Stop{}
}

pub fn (mut s Stop) request() {
	stdatomic.store_u64(&s.flag, 1)
}

pub fn (s &Stop) requested() bool {
	return stdatomic.load_u64(&s.flag) == 1
}
