module engine

// Integration tests: drain_timeout waits on an in-flight connection (#41).
// Stop accept via ListenBreak (no OS signals).

import net
import time
import viltrum.http

fn drain_free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('free_addr listen: ${err}') }
	a := l.addr() or {
		l.close() or {}
		panic('free_addr addr: ${err}')
	}
	s := a.str()
	l.close() or {}
	return s
}

fn drain_wait_listen() {
	time.sleep(100 * time.millisecond)
}

fn wait_active(mut stats ConnStats, timeout time.Duration) bool {
	start := time.now()
	for {
		if stats.active() > 0 {
			return true
		}
		if time.since(start) >= timeout {
			return false
		}
		time.sleep(5 * time.millisecond)
	}
	return false
}

fn wait_flag(shared flag SignalStop, timeout time.Duration) bool {
	start := time.now()
	for {
		if signal_stop_get(shared flag) {
			return true
		}
		if time.since(start) >= timeout {
			return false
		}
		time.sleep(5 * time.millisecond)
	}
	return false
}

fn test_drain_timeout_waits_for_inflight_handler() {
	addr := drain_free_addr()
	mut br := &ListenBreak{}
	mut stats := new_conn_stats()
	opts := ServerOptions{
		handle_signals: false
		drain_timeout:  1 * time.second
		stats:          stats
		listen_break:   br
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
	}
	shared done := SignalStop{}
	spawn fn [addr, opts, shared done] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			time.sleep(200 * time.millisecond)
			return http.Response.text(200, 'drained')
		}, []UpgradeRoute{}, opts) or {}
		signal_stop_set(shared done)
	}()
	drain_wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(3 * time.second)
	client.set_write_timeout(3 * time.second)
	client.write('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.bytes()) or {
		assert false, 'write: ${err}'
		return
	}
	if !wait_active(mut stats, 1 * time.second) {
		assert false, 'handler never accepted'
		return
	}

	t0 := time.now()
	br.fire()
	if !wait_flag(shared done, 2 * time.second) {
		assert false, 'listen did not return'
		return
	}
	elapsed := time.since(t0)
	assert elapsed >= 80 * time.millisecond, 'should wait for in-flight handler: ${elapsed}'
	assert elapsed < 800 * time.millisecond, 'should finish before drain cap: ${elapsed}'
	assert stats.active() == 0, 'drain_timeout > 0 should wait until active is 0'
}

fn test_drain_timeout_zero_returns_promptly() {
	addr := drain_free_addr()
	mut br := &ListenBreak{}
	mut stats := new_conn_stats()
	opts := ServerOptions{
		handle_signals: false
		drain_timeout:  0
		stats:          stats
		listen_break:   br
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
	}
	shared done := SignalStop{}
	spawn fn [addr, opts, shared done] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			time.sleep(250 * time.millisecond)
			return http.Response.text(200, 'still-running')
		}, []UpgradeRoute{}, opts) or {}
		signal_stop_set(shared done)
	}()
	drain_wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(3 * time.second)
	client.set_write_timeout(3 * time.second)
	client.write('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.bytes()) or {
		assert false, 'write: ${err}'
		return
	}
	if !wait_active(mut stats, 1 * time.second) {
		assert false, 'handler never accepted'
		return
	}

	t0 := time.now()
	br.fire()
	if !wait_flag(shared done, 2 * time.second) {
		assert false, 'listen did not return'
		return
	}
	elapsed := time.since(t0)
	assert elapsed < 150 * time.millisecond, 'drain_timeout=0 should return promptly: ${elapsed}'
	assert stats.active() > 0, 'handler should still be in-flight after drain_timeout=0'
}

fn test_drain_timeout_waits_for_hijacked_conn() {
	addr := drain_free_addr()
	mut br := &ListenBreak{}
	mut stats := new_conn_stats()
	opts := ServerOptions{
		handle_signals: false
		drain_timeout:  1 * time.second
		stats:          stats
		listen_break:   br
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
	}
	shared done := SignalStop{}
	spawn fn [addr, opts, shared done] () {
		upgrades := [
			UpgradeRoute{
				method:  'GET'
				pattern: '/hold'
				handler: fn (mut c Conn, req http.Request) {
					time.sleep(200 * time.millisecond)
					c.write_all(http.Response.text(200, 'hijack-drain').to_bytes()) or {}
					c.close() or {}
				}
			},
		]
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.not_found()
		}, upgrades, opts) or {}
		signal_stop_set(shared done)
	}()
	drain_wait_listen()

	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(3 * time.second)
	client.set_write_timeout(3 * time.second)
	client.write('GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		assert false, 'write: ${err}'
		return
	}
	if !wait_active(mut stats, 1 * time.second) {
		assert false, 'hijack never accepted'
		return
	}

	t0 := time.now()
	br.fire()
	if !wait_flag(shared done, 2 * time.second) {
		assert false, 'listen did not return'
		return
	}
	elapsed := time.since(t0)
	assert elapsed >= 80 * time.millisecond, 'should wait for hijacked conn: ${elapsed}'
	assert elapsed < 800 * time.millisecond, 'should finish before drain cap: ${elapsed}'
	assert stats.active() == 0, 'drain should wait for hijacked conn'
}
