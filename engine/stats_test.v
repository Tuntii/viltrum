module engine

// Unit tests for ConnStats + wait_drain (graceful shutdown / ops hooks).

import time

fn test_conn_stats_acquire_release_and_reject() {
	mut s := new_conn_stats()
	assert s.try_acquire(2) == true
	assert s.try_acquire(2) == true
	assert s.try_acquire(2) == false
	snap := s.snapshot()
	assert snap.active == 2
	assert snap.accepted == 2
	assert snap.rejected_max == 1
	assert snap.closed == 0

	s.release()
	assert s.active() == 1
	s.release()
	assert s.active() == 0
	snap2 := s.snapshot()
	assert snap2.closed == 2
	assert snap2.accepted == 2
}

fn test_conn_stats_unlimited_max() {
	mut s := new_conn_stats()
	// max 0 = unlimited
	assert s.try_acquire(0) == true
	assert s.try_acquire(0) == true
	assert s.active() == 2
	s.release()
	s.release()
	assert s.active() == 0
}

fn test_wait_drain_empty_returns_immediately() {
	mut s := new_conn_stats()
	start := time.now()
	wait_drain(mut s, 200 * time.millisecond)
	// Should not wait the full timeout when active is already 0.
	assert time.since(start) < 100 * time.millisecond
}

fn test_wait_drain_timeout_with_active() {
	mut s := new_conn_stats()
	assert s.try_acquire(0) == true
	start := time.now()
	wait_drain(mut s, 40 * time.millisecond)
	elapsed := time.since(start)
	assert elapsed >= 35 * time.millisecond
	assert s.active() == 1
	s.release()
}

fn test_wait_drain_zero_timeout_is_noop() {
	mut s := new_conn_stats()
	assert s.try_acquire(0) == true
	start := time.now()
	wait_drain(mut s, 0)
	assert time.since(start) < 30 * time.millisecond
	assert s.active() == 1
	s.release()
}

fn test_resolve_stats_external_vs_internal() {
	mut external := new_conn_stats()
	mut got := resolve_stats(external)
	assert got.try_acquire(0) == true
	assert external.active() == 1
	external.release()

	mut internal := resolve_stats(unsafe { nil })
	assert internal.try_acquire(0) == true
	// Internal counter is independent of external.
	assert external.active() == 0
	internal.release()
}
