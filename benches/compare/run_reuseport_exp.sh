#!/usr/bin/env bash
# PR6 experiment: single accept (default) vs SO_REUSEPORT multi-listener.
# Measures Viltrum only (oha), scenarios E/F. Does not change production default.
# Usage:
#   bash benches/compare/run_reuseport_exp.sh
#   WORKERS="1 2 4 8" bash benches/compare/run_reuseport_exp.sh
set -euo pipefail
export PATH="${HOME}/.local/bin:/tmp/v:${HOME}/.cargo/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/viltrum-reuseport-exp}"
mkdir -p "$OUT_DIR"
V_ADDR="127.0.0.1:18099"
V_BIN="/tmp/viltrum-reuseport-bin"
WORKERS_LIST="${WORKERS:-1 2 4 8}"

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

build_workers() {
	local w=$1
	cat >/tmp/viltrum-reuseport-main.v <<V
module main

import viltrum

fn ok(_ viltrum.Request) viltrum.Response {
	return viltrum.text(200, 'ok')
}

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals:  false
		accept_workers:  ${w}
	})
	app.use(viltrum.recover)
	app.get('/', ok)
	app.listen('127.0.0.1:18099') or { panic(err) }
}
V
	if v -prod -o "$V_BIN" /tmp/viltrum-reuseport-main.v 2>"$OUT_DIR/build_w${w}.err"; then
		echo "built accept_workers=${w} (-prod)"
	else
		v -o "$V_BIN" /tmp/viltrum-reuseport-main.v
		echo "built accept_workers=${w} (default)"
	fi
}

parse_rps() {
	local f=$1
	if grep -Eiq 'Requests/sec' "$f"; then
		grep -Ei 'Requests/sec' "$f" | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
		return
	fi
	echo "?"
}

SUMMARY="$OUT_DIR/summary.txt"
{
	echo "PR6 SO_REUSEPORT experiment"
	echo "date: $(date -Iseconds)"
	echo "machine: $(uname -srm)  nproc=$(nproc)"
	echo "oha: $(oha --version 2>/dev/null | head -1 || echo '?')"
	echo "workers: ${WORKERS_LIST}"
	echo
	printf '%-10s %-18s %-18s %-10s\n' 'workers' 'E_rps' 'F_rps' 'success'
} >"$SUMMARY"

cleanup() {
	fuser -k 18099/tcp 2>/dev/null || true
	if [[ -n "${SRV_PID:-}" ]]; then
		kill "$SRV_PID" 2>/dev/null || true
		wait "$SRV_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

for w in $WORKERS_LIST; do
	cleanup
	build_workers "$w"
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
		echo "workers=${w} failed to start" >&2
		cat "$OUT_DIR/srv_w${w}.log" >&2 || true
		exit 1
	fi

	echo "== accept_workers=${w} E (10s c=50) =="
	oha -z 10s -c 50 --no-tui "http://${V_ADDR}/" | tee "$OUT_DIR/E_w${w}.txt"
	e_rps=$(parse_rps "$OUT_DIR/E_w${w}.txt")

	echo "== accept_workers=${w} F (10s c=100) =="
	oha -z 10s -c 100 --no-tui "http://${V_ADDR}/" | tee "$OUT_DIR/F_w${w}.txt"
	f_rps=$(parse_rps "$OUT_DIR/F_w${w}.txt")

	succ='100%'
	if ! grep -Eiq 'Success rate:[[:space:]]*100' "$OUT_DIR/E_w${w}.txt" \
		|| ! grep -Eiq 'Success rate:[[:space:]]*100' "$OUT_DIR/F_w${w}.txt"; then
		succ='CHECK'
	fi
	printf '%-10s %-18s %-18s %-10s\n' "$w" "$e_rps" "$f_rps" "$succ" | tee -a "$SUMMARY"
	cleanup
	SRV_PID=
done

echo
echo "======== SUMMARY ========"
cat "$SUMMARY"
echo
echo "Raw logs: $OUT_DIR/"
echo "done"
