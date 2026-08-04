module engine

// TLS listen path (v0.6). mbedtls only; WSS reuses app.ws over the same Conn.
import net.mbedtls
import os
import viltrum.http

// TlsOptions configures in-process HTTPS (PEM file paths).
pub struct TlsOptions {
pub:
	// PEM certificate file path (required).
	cert_file string
	// PEM private key file path (required).
	key_file string
}

// validate_tls_options checks required paths before binding.
pub fn validate_tls_options(tls TlsOptions) ! {
	if tls.cert_file.len == 0 {
		return error('tls: cert_file is required')
	}
	if tls.key_file.len == 0 {
		return error('tls: key_file is required')
	}
	if !os.exists(tls.cert_file) {
		return error('tls: cert_file not found: ${tls.cert_file}')
	}
	if !os.exists(tls.key_file) {
		return error('tls: key_file not found: ${tls.key_file}')
	}
}

// listen_and_serve_tls is TLS with default options and no upgrade routes.
pub fn listen_and_serve_tls(addr string, handler Handler, tls TlsOptions) ! {
	listen_and_serve_tls_full(addr, handler, []UpgradeRoute{}, ServerOptions{}, tls)!
}

// listen_and_serve_tls_full is the HTTPS entry: HTTP handler + optional upgrade routes over TLS.
// WSS = this listener + app.ws / UpgradeRoute (no second WebSocket stack).
pub fn listen_and_serve_tls_full(addr string, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, tls TlsOptions) ! {
	validate_tls_options(tls)!

	mut listener := mbedtls.new_ssl_listener(addr, mbedtls.SSLConnectConfig{
		cert:         tls.cert_file
		cert_key:     tls.key_file
		validate:     false // server does not verify clients (no mTLS in v0.6)
		read_timeout: opts.read_timeout
	})!
	shared stopping := SignalStop{}
	mut active := &ActiveConns{}
	pool := start_conn_pool(opts.conn_workers, handler, upgrades, opts, active)

	if opts.handle_signals {
		os.signal_opt(.int, fn [shared stopping, mut listener] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGINT)')
			listener.shutdown() or {}
		}) or {}
		os.signal_opt(.term, fn [shared stopping, mut listener] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGTERM)')
			listener.shutdown() or {}
		}) or {}
	}

	defer {
		listener.shutdown() or {}
		pool.close()
	}
	if pool.enabled {
		eprintln('[viltrum] listening on https://${addr} (conn_workers=${pool.n})')
	} else {
		eprintln('[viltrum] listening on https://${addr}')
	}
	for {
		if opts.handle_signals && signal_stop_get(shared stopping) {
			break
		}
		mut ssl := listener.accept() or {
			if opts.handle_signals && signal_stop_get(shared stopping) {
				break
			}
			msg := err.msg().to_lower()
			if msg.contains('closed') || msg.contains('invalid') || msg.contains('bad file')
				|| msg.contains('shutdown') {
				break
			}
			// Handshake failures and accept errors: log and keep listening.
			eprintln('[viltrum] tls accept error: ${err}')
			continue
		}

		track := opts.max_conns > 0
		if track {
			mut ok := false
			unsafe {
				mut a := &ActiveConns(active)
				ok = a.try_acquire(opts.max_conns)
			}
			if !ok {
				mut busy := http.Response.text(503, 'service unavailable')
				busy.set_connection_close()
				apply_response_defaults(mut busy, opts)
				// Best-effort 503; do not keep the TLS conn.
				mut tmp := Conn.wrap_ssl(ssl, []u8{})
				tmp.write_all(busy.to_bytes()) or {}
				tmp.close() or {}
				continue
			}
		}

		c := Conn.wrap_ssl(ssl, []u8{})
		// Ownership of the ssl handle moves to pool worker or spawn.
		dispatch_conn(c, handler, upgrades, opts, active, track, pool)
	}
	eprintln('[viltrum] stopped')
}
