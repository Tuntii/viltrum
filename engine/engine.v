module engine

// TCP accept + HTTP/1.1 framing + upgrade/hijack (v0.4).
// Conn is the single I/O surface for cleartext and TLS (v0.6).
import net
import os
import sync
import time
import viltrum.http

pub type Handler = fn (req http.Request) http.Response

pub struct ServerOptions {
pub:
	read_chunk_size  int           = 8 * 1024
	max_header_bytes int           = 64 * 1024
	max_body_bytes   int           = 1 * 1024 * 1024
	read_timeout     time.Duration = 30 * time.second
	write_timeout    time.Duration = 30 * time.second
	idle_timeout     time.Duration = 60 * time.second
	// read_header_timeout applies while assembling headers; 0 means use read_timeout.
	read_header_timeout time.Duration
	// max_conns bounds concurrent connections (0 = unlimited). Excess accepts get 503 then close.
	max_conns int
	// drain_timeout: after accept stops, wait for in-flight connections to finish
	// (up to this duration). 0 (default) = return as soon as the accept loop ends
	// (in-flight handlers may still be running). Used with SIGINT/SIGTERM shutdown.
	drain_timeout time.Duration
	// stats, if non-nil, is updated by the engine (active / accepted / rejected / closed).
	// Pass a heap ConnStats you own to poll counters from outside the accept loop.
	// When nil, the engine keeps an internal counter (still used for max_conns + drain).
	stats &ConnStats = unsafe { nil }
	// send_date adds Date (HTTP-date, UTC) when the handler did not set Date. Default off.
	send_date bool
	// server_header if non-empty sets Server when the handler did not. Default empty (omit).
	server_header string
	require_host  bool = true
	// handle_signals installs SIGINT/SIGTERM shutdown (disable in embedded/bench/tests).
	handle_signals bool = true
	// accept_workers is how many accept loops / SO_REUSEPORT listeners to run.
	// Default 1 = single listener (production default). Values >1 enable the
	// Linux SO_REUSEPORT multi-listener experiment (PR6 / #22). Non-Linux falls
	// back to 1 with a stderr notice. Prefer keeping 1 unless measure shows a win.
	accept_workers int = 1
	// conn_workers is how many fixed connection workers process accepted Conns.
	// Default 0 = spawn one goroutine per connection (current production path).
	// N > 0 = accept enqueues Conn onto a channel; N workers run handle_conn
	// (keep-alive stays on that worker). Experimental spike toward ~120k E.
	conn_workers int
	// use_epoll enables the Linux epoll single-thread reactor instead of
	// spawn-per-conn (experimental). Cleartext only; upgrade/WS routes are
	// not served on this path. Non-Linux returns an error from listen.
	use_epoll bool
}

// ConnStats is a thread-safe connection counter for max_conns, graceful drain, and ops.
// Pass one via ServerOptions.stats to observe live numbers from your process.
pub struct ConnStats {
mut:
	mu            sync.Mutex
	active_       int
	accepted_     u64
	rejected_max_ u64
	closed_       u64
}

// ConnStatsSnapshot is a point-in-time view of ConnStats counters.
pub struct ConnStatsSnapshot {
pub:
	active       int
	accepted     u64
	rejected_max u64
	closed       u64
}

// new_conn_stats allocates a heap ConnStats for ServerOptions.stats.
pub fn new_conn_stats() &ConnStats {
	return &ConnStats{}
}

// active returns the current number of live connections (accepted and not yet closed).
pub fn (mut s ConnStats) active() int {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.active_
}

// snapshot returns accepted / rejected / closed totals plus active.
pub fn (mut s ConnStats) snapshot() ConnStatsSnapshot {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return ConnStatsSnapshot{
		active:       s.active_
		accepted:     s.accepted_
		rejected_max: s.rejected_max_
		closed:       s.closed_
	}
}

fn (mut s ConnStats) try_acquire(max int) bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if max > 0 && s.active_ >= max {
		s.rejected_max_++
		return false
	}
	s.active_++
	s.accepted_++
	return true
}

fn (mut s ConnStats) release() {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if s.active_ > 0 {
		s.active_--
	}
	s.closed_++
}

fn resolve_stats(opts ServerOptions) &ConnStats {
	if opts.stats != unsafe { nil } {
		// Caller-owned heap pointer; engine only mutates via ConnStats methods.
		return unsafe { opts.stats }
	}
	return &ConnStats{}
}

// wait_drain blocks until active connections reach 0 or timeout elapses.
// timeout <= 0 means no wait (immediate return).
fn wait_drain(mut stats ConnStats, timeout time.Duration) {
	if timeout <= 0 {
		return
	}
	start := time.now()
	for {
		if stats.active() <= 0 {
			return
		}
		if time.since(start) >= timeout {
			n := stats.active()
			if n > 0 {
				eprintln('[viltrum] drain timeout after ${timeout}: ${n} connection(s) still active')
			}
			return
		}
		time.sleep(5 * time.millisecond)
	}
}

pub fn listen_and_serve(addr string, handler Handler) ! {
	listen_and_serve_full(addr, handler, []UpgradeRoute{}, ServerOptions{})!
}

pub fn listen_and_serve_opt(addr string, handler Handler, opts ServerOptions) ! {
	listen_and_serve_full(addr, handler, []UpgradeRoute{}, opts)!
}

// SignalStop is a shared flag for graceful listener shutdown.
// Note: V's `if shared_bool` inside rlock is unreliable (treats as always true).
// Always copy the field to a local before branching.
struct SignalStop {
mut:
	stop bool
}

fn signal_stop_set(shared s SignalStop) {
	lock s {
		s.stop = true
	}
}

fn signal_stop_get(shared s SignalStop) bool {
	mut v := false
	rlock s {
		v = s.stop
	}
	return v
}

// listen_and_serve_full is the full server entry: HTTP handler + optional upgrade routes.
pub fn listen_and_serve_full(addr string, handler Handler, upgrades []UpgradeRoute, opts ServerOptions) ! {
	if opts.use_epoll {
		if upgrades.len > 0 {
			eprintln('[viltrum] use_epoll: upgrade/WS routes are not served on the reactor path')
		}
		serve_epoll(addr, handler, opts)!
		return
	}
	workers := normalize_accept_workers(opts.accept_workers)
	shared stopping := SignalStop{}
	mut stats := resolve_stats(opts)
	pool := start_conn_pool(opts.conn_workers, handler, upgrades, opts, stats)

	if workers == 1 {
		mut listener := net.listen_tcp(.ip, addr)!
		if opts.handle_signals {
			os.signal_opt(.int, fn [shared stopping, mut listener] () {
				signal_stop_set(shared stopping)
				eprintln('[viltrum] shutting down (SIGINT)')
				listener.close() or {}
			}) or {}
			os.signal_opt(.term, fn [shared stopping, mut listener] () {
				signal_stop_set(shared stopping)
				eprintln('[viltrum] shutting down (SIGTERM)')
				listener.close() or {}
			}) or {}
		}
		defer {
			listener.close() or {}
		}
		if pool.enabled {
			eprintln('[viltrum] listening on http://${addr} (conn_workers=${pool.n})')
		} else {
			eprintln('[viltrum] listening on http://${addr}')
		}
		accept_loop(mut listener, handler, upgrades, opts, stats, shared stopping, pool)
		pool.close()
		wait_drain(mut stats, opts.drain_timeout)
		eprintln('[viltrum] stopped')
		return
	}

	// Multi-listener (Linux SO_REUSEPORT). Experimental; default remains workers=1.
	mut set := &ListenerSet{}
	for _ in 0 .. workers {
		set.items << listen_tcp_reuseport(addr)!
	}
	if opts.handle_signals {
		os.signal_opt(.int, fn [shared stopping, mut set] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGINT)')
			set.close_all()
		}) or {}
		os.signal_opt(.term, fn [shared stopping, mut set] () {
			signal_stop_set(shared stopping)
			eprintln('[viltrum] shutting down (SIGTERM)')
			set.close_all()
		}) or {}
	}
	defer {
		set.close_all()
	}
	if pool.enabled {
		eprintln('[viltrum] listening on http://${addr} (accept_workers=${workers}, SO_REUSEPORT, conn_workers=${pool.n})')
	} else {
		eprintln('[viltrum] listening on http://${addr} (accept_workers=${workers}, SO_REUSEPORT)')
	}
	// Spawn workers-1 loops; run the last on this thread.
	for i in 0 .. workers - 1 {
		mut l := set.items[i]
		spawn accept_loop(mut l, handler, upgrades, opts, stats, shared stopping, pool)
	}
	mut main_l := set.items[workers - 1]
	accept_loop(mut main_l, handler, upgrades, opts, stats, shared stopping, pool)
	pool.close()
	wait_drain(mut stats, opts.drain_timeout)
	eprintln('[viltrum] stopped')
}

// ListenerSet holds multi-listener sockets so signal handlers can close them all.
struct ListenerSet {
mut:
	items []&net.TcpListener
}

fn (mut s ListenerSet) close_all() {
	for mut l in s.items {
		l.close() or {}
	}
}

fn normalize_accept_workers(n int) int {
	if n <= 1 {
		return 1
	}
	$if linux {
		return n
	} $else {
		eprintln('[viltrum] accept_workers=${n} needs Linux SO_REUSEPORT; using 1')
		return 1
	}
}

// listen_tcp_reuseport binds with SO_REUSEPORT so multiple listeners can share addr.
// Linux only (caller must gate via normalize_accept_workers).
fn listen_tcp_reuseport(addr string) !&net.TcpListener {
	mut s := net.new_tcp_socket(.ip)!
	// new_tcp_socket already sets SO_REUSEADDR; add SO_REUSEPORT before bind.
	val := 1
	r := C.setsockopt(s.handle, C.SOL_SOCKET, C.SO_REUSEPORT, &val, sizeof(int))
	if r != 0 {
		return error('SO_REUSEPORT setsockopt failed')
	}
	s.bind(addr)!
	res := C.listen(s.handle, 128)
	if res != 0 {
		return error('listen failed after SO_REUSEPORT bind')
	}
	// Match net.listen_tcp defaults: infinite accept wait (0 timeout = immediate fail).
	mut listener := &net.TcpListener{
		sock:           s
		accept_timeout: net.infinite_timeout
	}
	return listener
}

// ConnPool is a fixed set of workers that run handle_conn (optional, conn_workers > 0).
struct ConnPool {
	enabled bool
	n       int
	ch      chan Conn
}

fn start_conn_pool(n int, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, stats &ConnStats) ConnPool {
	if n <= 0 {
		return ConnPool{
			enabled: false
		}
	}
	// Bounded queue: backpressure into accept when workers are saturated.
	mut qcap := n * 64
	if qcap < 64 {
		qcap = 64
	}
	ch := chan Conn{cap: qcap}
	for _ in 0 .. n {
		spawn conn_worker(ch, handler, upgrades, opts, stats)
	}
	return ConnPool{
		enabled: true
		n:       n
		ch:      ch
	}
}

fn (p ConnPool) close() {
	if p.enabled {
		p.ch.close()
	}
}

fn (p ConnPool) submit(c Conn) {
	p.ch <- c
}

fn conn_worker(ch chan Conn, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, stats &ConnStats) {
	for {
		c := <-ch or { return }
		handle_conn(c, handler, upgrades, opts, stats)
	}
}

// dispatch_conn hands a Conn to the pool or spawns handle_conn (production default).
fn dispatch_conn(c Conn, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, stats &ConnStats, pool ConnPool) {
	if pool.enabled {
		pool.submit(c)
		return
	}
	spawn handle_conn(c, handler, upgrades, opts, stats)
}

// accept_loop is one accept + dispatch loop on a single listener.
fn accept_loop(mut listener net.TcpListener, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, stats &ConnStats, shared stopping SignalStop, pool ConnPool) {
	for {
		// handle_signals: poll stop flag without using `if shared_bool` (V pitfall).
		if opts.handle_signals && signal_stop_get(shared stopping) {
			break
		}
		mut tcp := listener.accept() or {
			if opts.handle_signals && signal_stop_get(shared stopping) {
				break
			}
			msg := err.msg().to_lower()
			if msg.contains('closed') || msg.contains('invalid') || msg.contains('bad file') {
				break
			}
			eprintln('[viltrum] accept error: ${err}')
			continue
		}

		mut ok := false
		unsafe {
			mut s := &ConnStats(stats)
			ok = s.try_acquire(opts.max_conns)
		}
		if !ok {
			// Bound reached: short 503 then close (no keep-alive, no handler).
			mut busy := http.Response.text(503, 'service unavailable')
			busy.set_connection_close()
			apply_response_defaults(mut busy, opts)
			mut busy_c := Conn.wrap(mut tcp, []u8{})
			busy_c.write_all(busy.to_bytes()) or {}
			busy_c.close() or {}
			continue
		}

		c := Conn.wrap(mut tcp, []u8{})
		// Ownership of the socket moves to a worker (pool) or a new goroutine (spawn).
		dispatch_conn(c, handler, upgrades, opts, stats, pool)
	}
}

fn handle_conn(c_in Conn, handler Handler, upgrades []UpgradeRoute, opts ServerOptions, stats &ConnStats) {
	mut c := c_in
	mut hijacked := false
	defer {
		unsafe {
			mut s := &ConnStats(stats)
			s.release()
		}
		if !hijacked {
			c.close() or {}
		}
	}

	c.set_read_timeout(opts.read_timeout)
	c.set_write_timeout(opts.write_timeout)

	mut leftover := []u8{}
	// Conn-local scratch: reused across keep-alive requests on this Conn.
	// tmp  — socket read chunk; assem — HTTP message assembly; write_buf — response wire.
	mut tmp := []u8{len: opts.read_chunk_size}
	mut assem := []u8{cap: opts.read_chunk_size}
	mut write_buf := []u8{}
	mut first := true
	for {
		if !first {
			c.set_read_timeout(opts.idle_timeout)
		}
		first = false

		raw := read_message(mut c, mut leftover, mut tmp, mut assem, opts) or {
			msg := err.msg()
			kind := classify_read_error(msg)
			if kind != 'eof' {
				eprintln('[viltrum] conn read: ${kind}: ${msg}')
			}
			if kind == 'limit' {
				mut resp := http.Response.text(413, msg)
				resp.set_connection_close()
				apply_response_defaults(mut resp, opts)
				c.write_all(resp.to_bytes()) or {}
			} else if kind == 'protocol' {
				mut resp := http.Response.bad_request(msg)
				resp.set_connection_close()
				apply_response_defaults(mut resp, opts)
				c.write_all(resp.to_bytes()) or {}
			}
			return
		}

		c.set_read_timeout(opts.read_timeout)

		req := http.parse_request(raw) or {
			eprintln('[viltrum] conn parse: protocol: ${err.msg()}')
			mut resp := http.Response.bad_request(err.msg())
			resp.set_connection_close()
			apply_response_defaults(mut resp, opts)
			c.write_all(resp.to_bytes()) or {}
			return
		}

		if opts.require_host && req.version.starts_with('HTTP/1.1') {
			if req.headers.get_or_lowered('host', '') == '' {
				mut resp := http.Response.bad_request('missing host header')
				resp.set_connection_close()
				apply_response_defaults(mut resp, opts)
				c.write_all(resp.to_bytes()) or {}
				return
			}
		}

		if req.body.len > opts.max_body_bytes {
			mut resp := http.Response.text(413, 'payload too large')
			resp.set_connection_close()
			apply_response_defaults(mut resp, opts)
			c.write_all(resp.to_bytes()) or {}
			return
		}

		// --- upgrade / hijack: leave HTTP loop, transfer Conn ownership ---
		if hit := match_upgrade(upgrades, req) {
			mut rq := req
			rq.params = hit.params.clone()
			// leftover holds bytes past this HTTP message (pipelined / early data).
			// Move them into Conn pushback; HTTP loop never resumes.
			if leftover.len > 0 {
				c.rbuf = leftover.clone()
				leftover = []u8{}
			}
			hijacked = true
			// Long-lived streams (WS, custom protocols): use the longer of
			// read_timeout and idle_timeout so quiet peers are not cut by the
			// short HTTP request timeout alone. Handlers may still call
			// set_read_timeout themselves.
			c.set_read_timeout(upgrade_read_timeout(opts))
			c.set_write_timeout(opts.write_timeout)
			hit.handler(mut c, rq)
			if !c.is_closed() {
				c.close() or {}
			}
			return
		}

		mut resp := handler(req)
		close_after := http.should_close(req, resp)
		if close_after {
			resp.headers.set_lowered('connection', 'close')
		} else if resp.headers.get_or_lowered('connection', '') == '' {
			resp.headers.set_lowered('connection', 'keep-alive')
		}
		apply_response_defaults(mut resp, opts)

		// Serialize into conn-local write_buf (capacity retained across requests).
		resp.to_bytes_for_method_into(mut write_buf, req.method)
		c.write_all(write_buf) or { return }
		if close_after {
			return
		}
		// Message buffer is no longer needed; recycle capacity for next assembly.
		// Request.body was a view into raw — safe only after handler + write finished.
		// finish_message may return a length-limited view; assem still owns the
		// underlying allocation and is truncated in place (cap retained).
		recycle_assembly(mut assem)
	}
}

// apply_response_defaults sets optional Date / Server when enabled and not already present.
// Does not run for upgrade handlers (they write their own bytes on Conn).
fn apply_response_defaults(mut resp http.Response, opts ServerOptions) {
	if opts.send_date && resp.headers.get_or_lowered('date', '') == '' {
		resp.headers.set_lowered('date', http.http_date(time.utc()))
	}
	if opts.server_header.len > 0 && resp.headers.get_or_lowered('server', '') == '' {
		resp.headers.set_lowered('server', opts.server_header)
	}
}

fn classify_read_error(msg string) string {
	return match true {
		msg in ['eof', 'eof during headers', 'eof during body'] { 'eof' }
		msg.contains('timeout') || msg.contains('timed out') { 'timeout' }
		msg in ['payload too large', 'headers too large', 'message too large'] { 'limit' }
		else { 'protocol' }
	}
}

fn header_timeout(opts ServerOptions) time.Duration {
	if opts.read_header_timeout > 0 {
		return opts.read_header_timeout
	}
	return opts.read_timeout
}

// upgrade_read_timeout is applied on Conn after hijack (app.upgrade / app.ws).
// HTTP keep-alive uses idle_timeout only between requests; after upgrade there
// is no keep-alive loop, so we take max(read_timeout, idle_timeout) as a
// sensible default for long-lived streams without silent infinite hang.
fn upgrade_read_timeout(opts ServerOptions) time.Duration {
	if opts.idle_timeout > opts.read_timeout {
		return opts.idle_timeout
	}
	return opts.read_timeout
}

// read_message assembles one HTTP message into `assem`, reusing that buffer's
// capacity across keep-alive requests. When leftover holds pipelined bytes it is
// copied into assem (assem capacity reused when large enough). Empty leftover no
// longer pays leftover.clone() into a fresh empty array.
fn read_message(mut c Conn, mut leftover []u8, mut tmp []u8, mut assem []u8, opts ServerOptions) ![]u8 {
	if leftover.len > 0 {
		seed_assembly(mut assem, leftover)
		leftover = []u8{}
	} else {
		// Truncate in place — keep capacity from prior keep-alive requests.
		unsafe {
			assem.len = 0
		}
	}

	mut sent_100 := false
	mut saw_bytes := assem.len > 0
	if saw_bytes {
		// Already have data (from prior leftover); apply header timeout for the rest.
		c.set_read_timeout(header_timeout(opts))
	}

	for {
		if hdr_end := index_of_double_crlf(assem) {
			body_start := hdr_end + 4
			hdr := unsafe { assem[..hdr_end] }

			// TE + CL together is a protocol error (RFC 9112); reject before TE-not-supported.
			te := transfer_encoding_present(hdr)
			cl_opt := content_length_from_headers(hdr)
			if te && cl_opt != none {
				return error('transfer-encoding and content-length conflict')
			}
			if te {
				return error('transfer-encoding not supported')
			}

			cl := cl_opt or { return finish_message(mut leftover, assem, body_start, 0) }
			if cl < 0 {
				return error('negative content-length')
			}
			if cl > opts.max_body_bytes {
				return error('payload too large')
			}

			// Body phase uses read_timeout (distinct from header timeout).
			c.set_read_timeout(opts.read_timeout)

			if !sent_100 && cl > 0 && expects_100_continue(hdr) {
				if assem.len < body_start + cl {
					c.write_all('HTTP/1.1 100 Continue\r\n\r\n'.bytes()) or {
						return error('write 100-continue failed')
					}
					sent_100 = true
				}
			}

			total := body_start + cl
			for assem.len < total {
				n := c.read(mut tmp) or { return err }
				if n <= 0 {
					return error('eof during body')
				}
				assem << tmp[..n]
				if assem.len > opts.max_header_bytes + opts.max_body_bytes {
					return error('message too large')
				}
			}
			return finish_message(mut leftover, assem, body_start, cl)
		}

		if assem.len > opts.max_header_bytes {
			return error('headers too large')
		}
		n := c.read(mut tmp) or { return err }
		if n <= 0 {
			if assem.len == 0 {
				return error('eof')
			}
			return error('eof during headers')
		}
		if !saw_bytes {
			// First byte after idle wait: switch to header assembly timeout.
			saw_bytes = true
			c.set_read_timeout(header_timeout(opts))
		}
		assem << tmp[..n]
	}
	return error('unreachable')
}

// seed_assembly copies `src` into assem, reusing capacity when possible.
fn seed_assembly(mut assem []u8, src []u8) {
	if assem.cap < src.len {
		assem = []u8{len: src.len}
	} else {
		unsafe {
			assem.len = src.len
		}
	}
	for i in 0 .. src.len {
		assem[i] = src[i]
	}
}

// recycle_assembly truncates the conn-local assembly buffer after the request
// body view is no longer live, keeping capacity for the next keep-alive read.
fn recycle_assembly(mut assem []u8) {
	unsafe {
		assem.len = 0
	}
}

// finish_message hands off one complete HTTP message from the assembly buffer.
// Exact-length reads return `buf` without a full-message clone (common keep-alive path).
// Over-read (pipelined bytes) clones only the leftover tail; the message is a
// length-limited view of the same assembly buffer so body octets are not copied again.
// unsafe slice: avoid V's implicit clone on `buf[..total]` (same pattern as header scans).
fn finish_message(mut leftover []u8, buf []u8, body_start int, cl int) []u8 {
	total := body_start + cl
	if buf.len > total {
		leftover = buf[total..].clone()
		return unsafe { buf[..total] }
	}
	return buf
}

fn index_of_double_crlf(buf []u8) ?int {
	if buf.len < 4 {
		return none
	}
	limit := buf.len - 3
	for i in 0 .. limit {
		if buf[i] == `\r` && buf[i + 1] == `\n` && buf[i + 2] == `\r` && buf[i + 3] == `\n` {
			return i
		}
	}
	return none
}

// content_length_from_headers scans raw header bytes (request line + fields, no
// trailing CRLFCRLF) for the first Content-Length field without stringifying the
// whole block. Case-insensitive name match; value parsed like string.int().
fn content_length_from_headers(header_bytes []u8) ?int {
	val := header_value_ci(header_bytes, 'content-length') or { return none }
	return parse_decimal_bytes(val)
}

// transfer_encoding_present is true when a Transfer-Encoding field exists with a
// non-empty value (after OWS trim). Byte-level; no full header stringification.
fn transfer_encoding_present(header_bytes []u8) bool {
	val := header_value_ci(header_bytes, 'transfer-encoding') or { return false }
	return val.len > 0
}

fn expects_100_continue(header_bytes []u8) bool {
	text := header_bytes.bytestr()
	lines := text.split('\r\n')
	for i in 1 .. lines.len {
		lower := lines[i].to_lower()
		if lower.starts_with('expect:') {
			val := lower['expect:'.len..].trim_space()
			return val == '100-continue'
		}
	}
	return false
}

// header_value_ci returns the first header field value whose name matches
// name_lower (ASCII lower-case, no colon). Skips the request line. Match requires
// name then ':' with no space between (same as prior starts_with path). Value is
// trimmed of leading/trailing SP and HTAB only.
fn header_value_ci(header_bytes []u8, name_lower string) ?[]u8 {
	nlen := name_lower.len
	mut i := 0
	mut line_idx := 0
	for i <= header_bytes.len {
		mut j := i
		for j < header_bytes.len {
			if j + 1 < header_bytes.len && header_bytes[j] == `\r` && header_bytes[j + 1] == `\n` {
				break
			}
			j++
		}
		if line_idx > 0 && j >= i {
			line_len := j - i
			if line_len >= nlen + 1 {
				mut ok := true
				for k in 0 .. nlen {
					if ascii_lower(header_bytes[i + k]) != name_lower[k] {
						ok = false
						break
					}
				}
				if ok && header_bytes[i + nlen] == `:` {
					return trim_ows(header_bytes[i + nlen + 1..j])
				}
			}
		}
		line_idx++
		if j + 1 < header_bytes.len && header_bytes[j] == `\r` && header_bytes[j + 1] == `\n` {
			i = j + 2
			if i > header_bytes.len {
				break
			}
			continue
		}
		break
	}
	return none
}

@[inline]
fn ascii_lower(b u8) u8 {
	if b >= `A` && b <= `Z` {
		return b + 32
	}
	return b
}

// trim_ows trims HTTP optional whitespace (SP / HTAB) from both ends.
fn trim_ows(b []u8) []u8 {
	mut s := 0
	mut e := b.len
	for s < e && (b[s] == ` ` || b[s] == `\t`) {
		s++
	}
	for e > s && (b[e - 1] == ` ` || b[e - 1] == `\t`) {
		e--
	}
	if s == 0 && e == b.len {
		return b
	}
	return b[s..e]
}

// parse_decimal_bytes mirrors string.int() for optional leading '-' and digits.
fn parse_decimal_bytes(b []u8) int {
	if b.len == 0 {
		return 0
	}
	mut i := 0
	mut neg := false
	if b[0] == `-` {
		neg = true
		i = 1
	} else if b[0] == `+` {
		i = 1
	}
	mut n := 0
	for i < b.len {
		c := b[i]
		if c < `0` || c > `9` {
			break
		}
		n = n * 10 + int(c - `0`)
		i++
	}
	if neg {
		return -n
	}
	return n
}
