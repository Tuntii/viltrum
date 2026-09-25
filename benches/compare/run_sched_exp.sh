#!/usr/bin/env bash
# Runtime scheduler A/B (benches/compare/RUNTIME.md).
#
# V 0.5.2 `spawn` is pthread_create + detach (one OS thread per connection).
# There is no GOMAXPROCS for that path. VJOBS changes runtime.nr_jobs() only
# (compiler pool, sync.pool, photon `go`). Viltrum's accept loop uses `spawn`,
# not `go`, so VJOBS is not a server knob.
#
# Prescribed fallback: one already-in-tree knob, process-level accept_workers.
# Baseline = 1 (production default). Variant = 8 (single-run peak in
# REUSEPORT.md; still one knob, not a sweep). Same oha shapes as RESULTS:
#   E  GET /  -z 10s -c 50
#   F  GET /  -z 10s -c 100
# Three runs, median. Axum peer on the same args, same session.
# Does not change the production default.
#
# Usage:
#   bash benches/compare/run_sched_exp.sh
#   VARIANT=8 RUNS=3 bash benches/compare/run_sched_exp.sh
set -euo pipefail
export PATH="${HOME}/.local/bin:/tmp/v:${HOME}/.cargo/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/viltrum-sched-exp}"
mkdir -p "$OUT_DIR"
V_ADDR="127.0.0.1:18099"
AX_ADDR="127.0.0.1:18098"
V_BIN="/tmp/viltrum-sched-bin"
AX_BIN="${AX_BIN:-$ROOT/benches/compare/axum/target/release/viltrum-bench-axum}"
VARIANT="${VARIANT:-8}"
RUNS="${RUNS:-3}"

need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "missing: $1" >&2
		exit 2
	}
}
need oha
need v
need curl
[[ -x "$AX_BIN" ]] || {
	echo "missing axum bench binary: $AX_BIN" >&2
	exit 2
}

ln -sfn "$ROOT" "${HOME}/.vmodules/viltrum"

# Prove VJOBS reaches runtime.nr_jobs on this toolchain. Not a throughput run.
cat >/tmp/viltrum-nrjobs.v <<'V'
module main

import runtime

fn main() {
	println(runtime.nr_jobs())
}
V
nj_default="$(v run /tmp/viltrum-nrjobs.v)"
nj_1="$(VJOBS=1 v run /tmp/viltrum-nrjobs.v)"
nj_16="$(VJOBS=16 v run /tmp/viltrum-nrjobs.v)"

build_workers() {
	local w=$1
	cat >/tmp/viltrum-sched-main.v <<V
module main

import viltrum

fn ok(_ viltrum.Request) viltrum.Response {
	return viltrum.text(200, 'ok')
}

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: false
		accept_workers: ${w}
	})
	app.use(viltrum.recover)
	app.get('/', ok)
	app.listen('127.0.0.1:18099') or { panic(err) }
}
V
	if v -prod -keepc -o "$V_BIN" /tmp/viltrum-sched-main.v 2>"$OUT_DIR/build_w${w}.err"; then
		echo "built accept_workers=${w} (-prod)"
	else
		echo "viltrum -prod failed for accept_workers=${w}; see $OUT_DIR/build_w${w}.err" >&2
		exit 1
	fi
}

parse_rps() {
	local f=$1
	if grep -Eiq 'Requests/sec' "$f"; then
		grep -Ei 'Requests/sec' "$f" | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
		return
	fi
	echo "0"
}

median_of() {
	sort -n | awk '{
		a[NR]=$1
	}
	END {
		if (NR==0) { print 0; exit }
		if (NR%2) print a[(NR+1)/2]
		else print (a[NR/2]+a[NR/2+1])/2
	}'
}

SUMMARY="$OUT_DIR/summary.txt"
{
	echo "runtime scheduler A/B (spawn path)"
	echo "date: $(date -Iseconds)"
	echo "machine: $(uname -srm)  nproc=$(nproc)"
	echo "v: $(v version 2>&1 | head -1)"
	echo "oha: $(oha --version 2>/dev/null | head -1 || echo '?')"
	echo "variant accept_workers=${VARIANT}  runs=${RUNS}"
	echo "VJOBS probe nr_jobs: default=${nj_default} VJOBS=1 -> ${nj_1} VJOBS=16 -> ${nj_16}"
	echo "spawn knob: none. V 0.5 spawn is pthread_create; VJOBS does not size the accept loop."
	echo "fallback knob: ServerOptions.accept_workers (SO_REUSEPORT listeners). conn_workers stays 0."
	echo
} >"$SUMMARY"

cleanup() {
	fuser -k 18099/tcp >/dev/null 2>&1 || true
	fuser -k 18098/tcp >/dev/null 2>&1 || true
	if [[ -n "${SRV_PID:-}" ]]; then
		kill "$SRV_PID" 2>/dev/null || true
		wait "$SRV_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

note_spawn_codegen() {
	local cfile=""
	for cand in /tmp/viltrum-sched-main.c /tmp/viltrum-sched-main.tmp.c; do
		if [[ -f "$cand" ]]; then
			cfile=$cand
			break
		fi
	done
	if [[ -z "$cfile" ]]; then
		cfile="$(find /tmp/v_1000 -name 'viltrum-sched-main.c' -o -name 'viltrum-sched-main.tmp.c' 2>/dev/null | head -1 || true)"
	fi
	if [[ -n "$cfile" && -f "$cfile" ]]; then
		local pc ph
		pc="$(grep -c 'pthread_create' "$cfile" || true)"
		ph="$(grep -c 'photon_thread_create' "$cfile" || true)"
		echo "codegen: ${cfile}  pthread_create=${pc}  photon_thread_create=${ph}" | tee -a "$SUMMARY"
	else
		echo "codegen: generated C not found (keepc); source evidence still stands" | tee -a "$SUMMARY"
	fi
}

run_mode() {
	local label=$1
	local kind=$2
	local workers=${3:-}

	cleanup
	SRV_PID=
	if [[ "$kind" == "viltrum" ]]; then
		build_workers "$workers"
		if [[ "$workers" == "1" ]]; then
			note_spawn_codegen
		fi
		"$V_BIN" >"$OUT_DIR/srv_${label}.log" 2>&1 &
		SRV_PID=$!
		local url="http://${V_ADDR}/"
	else
		"$AX_BIN" >"$OUT_DIR/srv_${label}.log" 2>&1 &
		SRV_PID=$!
		local url="http://${AX_ADDR}/"
	fi

	local ok=0
	for _ in $(seq 1 200); do
		if curl -sf "$url" >/dev/null 2>&1; then
			ok=1
			break
		fi
		sleep 0.05
	done
	if [[ $ok -ne 1 ]]; then
		echo "${label} failed to start" >&2
		cat "$OUT_DIR/srv_${label}.log" >&2 || true
		exit 1
	fi

	local e_list="" f_list="" succ='100%'
	for r in $(seq 1 "$RUNS"); do
		echo "== ${label} run ${r}/${RUNS} E =="
		oha -z 10s -c 50 --no-tui "$url" | tee "$OUT_DIR/E_${label}_r${r}.txt"
		local e f
		e=$(parse_rps "$OUT_DIR/E_${label}_r${r}.txt")
		e_list="${e_list}${e}"$'\n'

		echo "== ${label} run ${r}/${RUNS} F =="
		oha -z 10s -c 100 --no-tui "$url" | tee "$OUT_DIR/F_${label}_r${r}.txt"
		f=$(parse_rps "$OUT_DIR/F_${label}_r${r}.txt")
		f_list="${f_list}${f}"$'\n'

		if ! grep -Eiq 'Success rate:[[:space:]]*100' "$OUT_DIR/E_${label}_r${r}.txt" \
			|| ! grep -Eiq 'Success rate:[[:space:]]*100' "$OUT_DIR/F_${label}_r${r}.txt"; then
			succ='CHECK'
		fi
	done
	local e_med f_med e_raw
	e_med=$(printf '%s' "$e_list" | median_of)
	f_med=$(printf '%s' "$f_list" | median_of)
	e_raw=$(printf '%s' "$e_list" | awk 'NF{printf "%s%s", (n++?", ":""), $1}')
	printf '%-16s %-14s %-14s %-12s %-10s\n' "$label" "$e_med" "$f_med" "$e_raw" "$succ" | tee -a "$SUMMARY"
	echo "raw ${label} F: $(printf '%s' "$f_list" | awk 'NF{printf "%s%s", (n++?", ":""), $1}')" | tee -a "$SUMMARY"
	cleanup
	SRV_PID=
}

printf '%-16s %-14s %-14s %-12s %-10s\n' 'mode' 'E_median' 'F_median' 'E_runs' 'success' | tee -a "$SUMMARY"

run_mode "accept_1" viltrum 1
run_mode "accept_${VARIANT}" viltrum "$VARIANT"
run_mode "axum" axum

echo
echo "======== SUMMARY ========"
cat "$SUMMARY"
echo
echo "Raw logs: $OUT_DIR/"
echo "done"
