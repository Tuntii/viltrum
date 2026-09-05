module engine

// TLS listen path (v0.6). mbedtls only; WSS reuses app.ws over the same Conn.
import net.mbedtls
import os
import time
import viltrum.http

// TlsOptions configures in-process HTTPS (PEM file paths).
pub struct TlsOptions {
pub:
	// PEM certificate file path (required).
	cert_file string
	// PEM private key file path (required).
	key_file string
	// reload_on_sighup: SIGHUP re-reads cert/key and replaces the TLS listener.
	// In-flight connections keep the old cert. A failed reload (missing or
	// corrupt PEM) logs and keeps serving the previous cert. Default off.
	reload_on_sighup bool
}

// TlsHold is a heap wrapper so signal handlers always close the current listener.
struct TlsHold {
mut:
	l &mbedtls.SSLListener = unsafe { nil }
}

fn (mut h TlsHold) shutdown() {
	if h.l != unsafe { nil } {
		h.l.shutdown() or {}
	}
}

fn new_tls_listener(addr string, tls TlsOptions, opts ServerOptions) !&mbedtls.SSLListener {
	return mbedtls.new_ssl_listener(addr, mbedtls.SSLConnectConfig{
		cert:         tls.cert_file
		cert_key:     tls.key_file
		validate:     false // server does not verify clients (no mTLS in v0.6)
		read_timeout: opts.read_timeout
	})
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

// tls_files_ready checks paths and that mbedtls can load the PEM pair.
// Binds a throwaway listener on 127.0.0.1:0 so the live socket is untouched.
fn tls_files_ready(tls TlsOptions, opts ServerOptions) ! {
	validate_tls_options(tls)!
	mut probe := new_tls_listener('127.0.0.1:0', tls, opts)!
	probe.shutdown() or {}
}

// swap_tls_listener drops the current listener and binds a replacement.
// PEM must already have been validated; this only rebinds the live address.
fn swap_tls_listener(mut hold TlsHold, addr string, tls TlsOptions, opts ServerOptions) ! {
	hold.shutdown()
	hold.l = new_tls_listener(addr, tls, opts)!
}

// try_reload_tls validates the PEM pair before dropping the live listener.
// On validation failure the current listener is left serving.
fn try_reload_tls(mut hold TlsHold, addr string, tls TlsOptions, opts ServerOptions) ! {
	tls_files_ready(tls, opts)!
	swap_tls_listener(mut hold, addr, tls, opts)!
}

// listen_and_serve_tls is TLS with default options and no upgrade routes.
pub fn listen_and_serve_tls(addr string, handler Handler, tls TlsOptions) ! {
	listen_and_serve_tls_full(addr, handler, []UpgradeRoute{}, ServerOptions{}, tls)!
}

// listen_and_serve_tls_full is the HTTPS entry: HTTP handler + optional upgrade routes over TLS.
// WSS = this listener + app.ws / UpgradeRoute (no second WebSocket stack).
pub fn listen_and_serve_tls_full(addr string, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, tls TlsOptions) ! {
	validate_tls_options(tls)!

	mut hold := &TlsHold{
		l: new_tls_listener(addr, tls, opts)!
	}
	if opts.listen_break != unsafe { nil } {
		unsafe {
			opts.listen_break.tls = hold
		}
	}
	shared stopping := SignalStop{}
	shared reloading := SignalStop{}
	shared rebind := SignalStop{}
	mut stats := resolve_stats(opts.stats)
	pool := start_conn_pool(opts.conn_workers, handler, upgrades, opts, stats)

	if opts.handle_signals {
		os.signal_opt(.int, fn [shared stopping, mut hold] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGINT)')
			hold.shutdown()
		}) or {}
		os.signal_opt(.term, fn [shared stopping, mut hold] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGTERM)')
			hold.shutdown()
		}) or {}
	}
	if tls.reload_on_sighup {
		os.signal_opt(.hup, fn [shared reloading, mut hold, tls, opts] () {
			eprintln('[viltrum] SIGHUP: reloading TLS cert')
			tls_files_ready(tls, opts) or {
				eprintln('[viltrum] tls reload failed: ${err}')
				return
			}
			signal_stop_set(shared reloading)
			hold.shutdown()
		}) or {}
	}

	defer {
		hold.shutdown()
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
		if listen_break_fired(opts) {
			break
		}
		mut ssl := hold.l.accept() or {
			if opts.handle_signals && signal_stop_get(shared stopping) {
				break
			}
			if listen_break_fired(opts) {
				break
			}
			if listen_break_take_reload(opts) {
				swap_tls_listener(mut hold, addr, tls, opts) or {
					eprintln('[viltrum] tls reload failed: ${err}')
					continue
				}
				eprintln('[viltrum] tls cert reloaded')
				continue
			}
			if tls.reload_on_sighup && (signal_stop_get(shared reloading)
				|| signal_stop_get(shared rebind)) {
				signal_stop_clear(shared reloading)
				signal_stop_set(shared rebind)
				swap_tls_listener(mut hold, addr, tls, opts) or {
					eprintln('[viltrum] tls reload failed: ${err}')
					time.sleep(20 * time.millisecond)
					continue
				}
				signal_stop_clear(shared rebind)
				eprintln('[viltrum] tls cert reloaded')
				continue
			}
			msg := err.msg().to_lower()
			if msg.contains('closed') || msg.contains('invalid') || msg.contains('bad file')
				|| msg.contains('shutdown') {
				if tls.reload_on_sighup && signal_stop_get(shared rebind) {
					continue
				}
				break
			}
			// Handshake failures and accept errors: log and keep listening.
			eprintln('[viltrum] tls accept error: ${err}')
			continue
		}

		mut ok := false
		unsafe {
			mut s := &ConnStats(stats)
			ok = s.try_acquire(opts.max_conns)
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

		c := Conn.wrap_ssl(ssl, []u8{})
		// Ownership of the ssl handle moves to pool worker or spawn.
		dispatch_conn(c, handler, upgrades, opts, stats, pool)
	}
	pool.close()
	wait_drain(mut stats, opts.drain_timeout)
	eprintln('[viltrum] stopped')
}
