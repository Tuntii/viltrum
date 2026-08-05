#!/usr/bin/env bash
# Worker-pool spike A/B: conn_workers=0 (spawn-per-conn) vs N (fixed pool).
# Viltrum only, scenarios E/F, 3 runs each for median. Default production is 0.
# Usage:
#   bash benches/compare/run_conn_pool_exp.sh
#   MODES="0 8 16" RUNS=3 bash benches/compare/run_conn_pool_exp.sh
set -euo pipefail
export PATH="${HOME}/.local/bin:/tmp/v:${HOME}/.cargo/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/viltrum-conn-pool-exp}"
mkdir -p "$OUT_DIR"
V_ADDR="127.0.0.1:18099"
V_BIN="/tmp/viltrum-conn-pool-bin"
MODES="${MODES:-0 8 16}"
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

ln -sfn "$ROOT" "${HOME}/.vmodules/viltrum"

build_mode() {
	local w=$1
	cat >/tmp/viltrum-conn-pool-main.v <<V
module main

import viltrum

fn ok(_ viltrum.Request) viltrum.Response {
	return viltrum.text(200, 'ok')
}

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: false
		conn_workers:   ${w}
	})
	app.use(viltrum.recover)
	app.get('/', ok)
	app.listen('127.0.0.1:18099') or { panic(err) }
}
V
	if v -prod -o "$V_BIN" /tmp/viltrum-conn-pool-main.v 2>"$OUT_DIR/build_w${w}.err"; then
		echo "built conn_workers=${w} (-prod)"
	else
		v -o "$V_BIN" /tmp/viltrum-conn-pool-main.v
		echo "built conn_workers=${w} (default)"
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

median3() {
	# stdin: one number per line; print median of sorted values
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
	echo "conn_workers pool A/B"
	echo "date: $(date -Iseconds)"
	echo "machine: $(uname -srm)  nproc=$(nproc)"
	echo "oha: $(oha --version 2>/dev/null | head -1 || echo '?')"
	echo "modes: ${MODES}  runs: ${RUNS}"
	echo
	printf '%-12s %-14s %-14s %-10s\n' 'conn_workers' 'E_median' 'F_median' 'success'
} >"$SUMMARY"

cleanup() {
	fuser -k 18099/tcp 2>/dev/null || true
	if [[ -n "${SRV_PID:-}" ]]; then
		kill "$SRV_PID" 2>/dev/null || true
		wait "$SRV_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

for w in $MODES; do
	cleanup
	build_mode "$w"
	"$V_BIN" >"$OUT_DIR/srv_w${w}.log" 2>&1 &
	SRV_PID=$!
	ok=0
	for _ in $(seq 1 200); do
		if curl -sf "http://${V_ADDR}/" >/dev/null 2>&1; then
			ok=1
			break
		fi
		sleep 0.05
	done
	if [[ $ok -ne 1 ]]; then
		echo "conn_workers=${w} failed to start" >&2
		cat "$OUT_DIR/srv_w${w}.log" >&2 || true
		exit 1
	fi

	e_list=""
	f_list=""
	succ='100%'
	for r in $(seq 1 "$RUNS"); do
		echo "== conn_workers=${w} run ${r}/${RUNS} E =="
		oha -z 10s -c 50 --no-tui "http://${V_ADDR}/" | tee "$OUT_DIR/E_w${w}_r${r}.txt"
		e=$(parse_rps "$OUT_DIR/E_w${w}_r${r}.txt")
		e_list="${e_list}${e}"$'\n'

		echo "== conn_workers=${w} run ${r}/${RUNS} F =="
		oha -z 10s -c 100 --no-tui "http://${V_ADDR}/" | tee "$OUT_DIR/F_w${w}_r${r}.txt"
		f=$(parse_rps "$OUT_DIR/F_w${w}_r${r}.txt")
		f_list="${f_list}${f}"$'\n'

		if ! grep -Eiq 'Success rate:[[:space:]]*100' "$OUT_DIR/E_w${w}_r${r}.txt" \
			|| ! grep -Eiq 'Success rate:[[:space:]]*100' "$OUT_DIR/F_w${w}_r${r}.txt"; then
			succ='CHECK'
		fi
	done
	e_med=$(printf '%s' "$e_list" | median3)
	f_med=$(printf '%s' "$f_list" | median3)
	printf '%-12s %-14s %-14s %-10s\n' "$w" "$e_med" "$f_med" "$succ" | tee -a "$SUMMARY"
	cleanup
	SRV_PID=
done

echo
echo "======== SUMMARY ========"
cat "$SUMMARY"
echo
echo "Raw logs: $OUT_DIR/"
echo "done"
