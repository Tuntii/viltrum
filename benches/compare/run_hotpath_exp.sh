#!/usr/bin/env bash
# Hot-path A/B: spawn-per-conn vs one epoll loop per core.
# Shapes E (10s, c=50) and F (10s, c=100), three runs, with recover and without.
# Does not change the production default. See benches/compare/CORES.md after a run.
#
#   bash benches/compare/run_hotpath_exp.sh
#   RUNS=3 CORES=16 bash benches/compare/run_hotpath_exp.sh
set -euo pipefail
export PATH="${HOME}/.local/bin:/tmp/v:${HOME}/.cargo/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/viltrum-hotpath-exp}"
mkdir -p "$OUT_DIR"
V_ADDR="127.0.0.1:18099"
V_BIN="/tmp/viltrum-hotpath-bin"
RUNS="${RUNS:-3}"
CORES="${CORES:-$(nproc)}"

need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "missing: $1" >&2
		exit 2
	}
}
need oha
need v
need curl

ln -sfn "$ROOT" "${HOME}/.vmodules/viltrum"

build_mode() {
	local label=$1
	local cores=$2
	local recover=$3
	local use_line=""
	if [[ "$recover" == "1" ]]; then
		use_line='app.use(viltrum.recover)'
	fi
	cat >/tmp/viltrum-hotpath-main.v <<V
module main

import viltrum

fn ok(_ viltrum.Request) viltrum.Response {
	return viltrum.text(200, 'ok')
}

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: false
		epoll_cores:    ${cores}
	})
	${use_line}
	app.get('/', ok)
	app.listen('127.0.0.1:18099') or { panic(err) }
}
V
	if ! v -prod -o "$V_BIN" /tmp/viltrum-hotpath-main.v 2>"$OUT_DIR/build_${label}.err"; then
		echo "build failed: ${label}" >&2
		cat "$OUT_DIR/build_${label}.err" >&2
		exit 1
	fi
	echo "built ${label} (-prod, epoll_cores=${cores}, recover=${recover})"
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
	sort -n | awk '{ a[NR]=$1 }
	END {
		if (NR==0) { print 0; exit }
		if (NR%2) print a[(NR+1)/2]
		else print (a[NR/2]+a[NR/2+1])/2
	}'
}

SUMMARY="$OUT_DIR/summary.txt"
{
	echo "hot-path spawn vs epoll_cores"
	echo "date: $(date -Iseconds)"
	echo "machine: $(uname -srm)  nproc=$(nproc)  cores=${CORES}  runs=${RUNS}"
	echo "v: $(v version 2>&1 | head -1)"
	echo "oha: $(oha --version 2>/dev/null | head -1 || echo '?')"
	echo
	printf '%-18s %-14s %-14s %-10s\n' 'mode' 'E_median' 'F_median' 'success'
} >"$SUMMARY"

cleanup() {
	fuser -k 18099/tcp >/dev/null 2>&1 || true
	if [[ -n "${SRV_PID:-}" ]]; then
		kill "$SRV_PID" 2>/dev/null || true
		wait "$SRV_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

run_mode() {
	local label=$1
	local cores=$2
	local recover=$3
	cleanup
	SRV_PID=
	build_mode "$label" "$cores" "$recover"
	"$V_BIN" >"$OUT_DIR/srv_${label}.log" 2>&1 &
	SRV_PID=$!
	local ok=0
	for _ in $(seq 1 200); do
		if curl -sf "http://${V_ADDR}/" >/dev/null 2>&1; then
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
		oha -z 10s -c 50 --no-tui "http://${V_ADDR}/" | tee "$OUT_DIR/E_${label}_r${r}.txt"
		local e f
		e=$(parse_rps "$OUT_DIR/E_${label}_r${r}.txt")
		e_list="${e_list}${e}"$'\n'
		echo "== ${label} run ${r}/${RUNS} F =="
		oha -z 10s -c 100 --no-tui "http://${V_ADDR}/" | tee "$OUT_DIR/F_${label}_r${r}.txt"
		f=$(parse_rps "$OUT_DIR/F_${label}_r${r}.txt")
		f_list="${f_list}${f}"$'\n'
		if ! grep -Eiq 'Success rate:[[:space:]]*100' "$OUT_DIR/E_${label}_r${r}.txt" \
			|| ! grep -Eiq 'Success rate:[[:space:]]*100' "$OUT_DIR/F_${label}_r${r}.txt"; then
			succ='CHECK'
		fi
	done
	local e_med f_med
	e_med=$(printf '%s' "$e_list" | median_of)
	f_med=$(printf '%s' "$f_list" | median_of)
	printf '%-18s %-14s %-14s %-10s\n' "$label" "$e_med" "$f_med" "$succ" | tee -a "$SUMMARY"
	echo "raw ${label} E: $(printf '%s' "$e_list" | awk 'NF{printf "%s%s", (n++?", ":""), $1}')" | tee -a "$SUMMARY"
	echo "raw ${label} F: $(printf '%s' "$f_list" | awk 'NF{printf "%s%s", (n++?", ":""), $1}')" | tee -a "$SUMMARY"
	cleanup
	SRV_PID=
}

run_mode "spawn_recover" 0 1
run_mode "spawn_bare" 0 0
run_mode "cores_recover" "$CORES" 1
run_mode "cores_bare" "$CORES" 0

echo
echo "======== SUMMARY ========"
cat "$SUMMARY"
echo
echo "Raw logs: $OUT_DIR/"
echo "done"
