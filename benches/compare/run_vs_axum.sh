#!/usr/bin/env bash
# Side-by-side HTTP throughput: Viltrum (V -prod) vs Axum (Rust release).
# Same client (oha), same shapes, cleartext loopback. Honest laptop numbers.
set -euo pipefail
export PATH="${HOME}/.local/bin:/tmp/v:${HOME}/.cargo/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPARE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/viltrum-vs-axum}"
mkdir -p "$OUT_DIR"

V_ADDR="127.0.0.1:18099"
AX_ADDR="127.0.0.1:18098"
V_BIN="/tmp/viltrum-bench-bin"
AX_BIN="/tmp/axum-bench-bin"

need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "missing: $1" >&2
		exit 2
	}
}
need oha
need v
need cargo
need curl

ln -sfn "$ROOT" "${HOME}/.vmodules/viltrum"

# --- build Viltrum (same as benches/run.sh) ---
cat >/tmp/viltrum-bench-main.v <<'V'
module main

import viltrum

fn ok(_ viltrum.Request) viltrum.Response {
	return viltrum.text(200, 'ok')
}

fn echo(req viltrum.Request) viltrum.Response {
	title := req.json_string('title') or { '' }
	return viltrum.json(200, '{"t":"${title}"}')
}

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: false
	})
	app.use(viltrum.recover)
	app.get('/', ok)
	app.post('/echo', echo)
	app.listen('127.0.0.1:18099') or { panic(err) }
}
V

echo "== build Viltrum =="
if v -prod -o "$V_BIN" /tmp/viltrum-bench-main.v 2>/tmp/viltrum-bench-build.err; then
	echo "viltrum: -prod → $V_BIN"
else
	echo "viltrum: default build ( -prod failed )"
	v -o "$V_BIN" /tmp/viltrum-bench-main.v
fi

echo "== build Axum (release) =="
(
	cd "$COMPARE/axum"
	cargo build --release 2>&1 | tail -5
	cp -f target/release/viltrum-bench-axum "$AX_BIN"
)
echo "axum: $AX_BIN"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do
		kill "$p" 2>/dev/null || true
		wait "$p" 2>/dev/null || true
	done
	fuser -k 18099/tcp 2>/dev/null || true
	fuser -k 18098/tcp 2>/dev/null || true
}
trap cleanup EXIT

fuser -k 18099/tcp 2>/dev/null || true
fuser -k 18098/tcp 2>/dev/null || true

"$V_BIN" >"$OUT_DIR/viltrum-srv.log" 2>&1 &
PIDS+=($!)
"$AX_BIN" >"$OUT_DIR/axum-srv.log" 2>&1 &
PIDS+=($!)

wait_up() {
	local url=$1 name=$2
	for _ in $(seq 1 200); do
		if curl -sf "$url" >/dev/null 2>&1; then
			echo "$name up"
			return 0
		fi
		sleep 0.05
	done
	echo "$name failed to start; log:" >&2
	cat "$OUT_DIR/${name}-srv.log" >&2 || true
	exit 1
}
wait_up "http://${V_ADDR}/" viltrum
wait_up "http://${AX_ADDR}/" axum

# Parse req/s from oha text output (English + common layouts).
parse_rps() {
	local f=$1
	# oha prints e.g. "Requests/sec:  85150.1234" or "  85150.12 Requests/sec"
	if grep -Eiq 'Requests/sec' "$f"; then
		grep -Ei 'Requests/sec' "$f" | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
		return
	fi
	echo "?"
}

run_scenario() {
	local tag=$1
	shift
	# remaining: oha args without URL
	local v_out="$OUT_DIR/${tag}_viltrum.txt"
	local a_out="$OUT_DIR/${tag}_axum.txt"
	echo
	echo "== $tag =="
	echo "-- viltrum --"
	oha "$@" --no-tui "http://${V_ADDR}/" | tee "$v_out"
	echo "-- axum --"
	# For POST scenarios URL path differs: pass path as last optional env
	local ax_url="http://${AX_ADDR}/"
	if [[ "${POST_PATH:-}" == "echo" ]]; then
		ax_url="http://${AX_ADDR}/echo"
		# re-run viltrum with /echo already done if caller used full path in oha args
	fi
	# When caller passed full path via OHA_PATH:
	if [[ -n "${OHA_PATH:-}" ]]; then
		oha "$@" --no-tui "http://${AX_ADDR}${OHA_PATH}" | tee "$a_out"
	else
		oha "$@" --no-tui "$ax_url" | tee "$a_out"
	fi
	local vr ar
	vr=$(parse_rps "$v_out")
	ar=$(parse_rps "$a_out")
	printf 'SUMMARY %s  viltrum=%s  axum=%s req/s\n' "$tag" "$vr" "$ar" | tee -a "$OUT_DIR/summary.txt"
}

: >"$OUT_DIR/summary.txt"
echo "machine: $(uname -srm)  nproc=$(nproc)" | tee "$OUT_DIR/meta.txt"
echo "oha: $(oha --version 2>&1 | head -1)" | tee -a "$OUT_DIR/meta.txt"
echo "v: $(v version 2>&1 | head -1)" | tee -a "$OUT_DIR/meta.txt"
echo "rustc: $(rustc --version)" | tee -a "$OUT_DIR/meta.txt"
date -Is | tee -a "$OUT_DIR/meta.txt"

# A: short burst
OHA_PATH=/ run_scenario A_get_n10k_c100 -n 10000 -c 100

# D: longer fixed-n
OHA_PATH=/ run_scenario D_get_n50k_c50 -n 50000 -c 50

# E: sustained
OHA_PATH=/ run_scenario E_get_z10s_c50 -z 10s -c 50

# F: sustained higher c
OHA_PATH=/ run_scenario F_get_z10s_c100 -z 10s -c 100

# C: POST JSON (both servers: /echo)
echo
echo "== C_post_echo_n5k_c100 =="
oha -n 5000 -c 100 -m POST -H 'Content-Type: application/json' -d '{"title":"bench"}' \
	--no-tui "http://${V_ADDR}/echo" | tee "$OUT_DIR/C_post_viltrum.txt"
oha -n 5000 -c 100 -m POST -H 'Content-Type: application/json' -d '{"title":"bench"}' \
	--no-tui "http://${AX_ADDR}/echo" | tee "$OUT_DIR/C_post_axum.txt"
printf 'SUMMARY %s  viltrum=%s  axum=%s req/s\n' C_post_echo_n5k_c100 \
	"$(parse_rps "$OUT_DIR/C_post_viltrum.txt")" \
	"$(parse_rps "$OUT_DIR/C_post_axum.txt")" | tee -a "$OUT_DIR/summary.txt"

echo
echo "======== SUMMARY ========"
cat "$OUT_DIR/summary.txt"
echo
echo "Raw logs: $OUT_DIR/"
echo "done"
