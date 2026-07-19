#!/usr/bin/env bash
# Honest throughput smoke via oha. Prints results; does not claim lab numbers.
set -euo pipefail
export PATH="${HOME}/.local/bin:/tmp/v:${PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ln -sfn "$ROOT" "${HOME}/.vmodules/viltrum"

ADDR="127.0.0.1:18099"
BIN="/tmp/viltrum-bench-bin"
OUT_DIR="/tmp/viltrum-bench"
mkdir -p "$OUT_DIR"

if ! command -v oha >/dev/null 2>&1; then
	echo "oha missing; install from https://github.com/hatoo/oha/releases" >&2
	exit 2
fi
if ! command -v v >/dev/null 2>&1; then
	echo "v not on PATH" >&2
	exit 2
fi

cat > /tmp/viltrum-bench-main.v <<'V'
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

echo "== build =="
# -prod if available; fall back to default
if v -prod -o "$BIN" /tmp/viltrum-bench-main.v 2>/tmp/viltrum-bench-build.err; then
	echo "built with -prod → $BIN"
else
	echo "(-prod failed, using default build)"
	v -o "$BIN" /tmp/viltrum-bench-main.v
fi

fuser -k 18099/tcp 2>/dev/null || true
"$BIN" >/tmp/viltrum-bench-srv.log 2>&1 &
SRV_PID=$!
cleanup() {
	kill "$SRV_PID" 2>/dev/null || true
	wait "$SRV_PID" 2>/dev/null || true
	fuser -k 18099/tcp 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 100); do
	if curl -sf "http://${ADDR}/" >/dev/null 2>&1; then
		break
	fi
	sleep 0.05
done
curl -sf "http://${ADDR}/" >/dev/null || {
	echo "server failed to start; log:" >&2
	cat /tmp/viltrum-bench-srv.log >&2 || true
	exit 1
}

echo
echo "== A) GET /  n=10000 c=100 =="
oha -n 10000 -c 100 --no-tui "http://${ADDR}/" | tee "$OUT_DIR/a_get_c100.txt"

echo
echo "== B) GET /  n=10000 c=500 =="
oha -n 10000 -c 500 --no-tui "http://${ADDR}/" | tee "$OUT_DIR/b_get_c500.txt"

echo
echo "== C) POST /echo JSON  n=5000 c=100 =="
oha -n 5000 -c 100 -m POST \
	-H 'Content-Type: application/json' \
	-d '{"title":"bench"}' \
	--no-tui "http://${ADDR}/echo" | tee "$OUT_DIR/c_post_json.txt"

echo
echo "== D) GET /  n=50000 c=50 (longer) =="
oha -n 50000 -c 50 --no-tui "http://${ADDR}/" | tee "$OUT_DIR/d_get_long.txt"

echo
echo "== E) GET /  -z 10s c=50 (sustained) =="
oha -z 10s -c 50 --no-tui "http://${ADDR}/" | tee "$OUT_DIR/e_get_10s_c50.txt"

echo
echo "== F) GET /  -z 10s c=100 (sustained) =="
oha -z 10s -c 100 --no-tui "http://${ADDR}/" | tee "$OUT_DIR/f_get_10s_c100.txt"

echo
echo "Raw oha output: $OUT_DIR/"
echo "done"
