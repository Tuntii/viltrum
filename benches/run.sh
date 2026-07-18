#!/usr/bin/env bash
# Minimal throughput smoke. Prefer oha if installed; else sequential curl.
set -euo pipefail
export PATH="${HOME}/.local/bin:${PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ln -sfn "$ROOT" "${HOME}/.vmodules/viltrum"
ADDR="127.0.0.1:18099"
BIN="/tmp/viltrum-bench-bin"

cat > /tmp/viltrum-bench-main.v <<'V'
module main
import viltrum
fn ok(_ viltrum.Request) viltrum.Response { return viltrum.text(200, 'ok') }
fn main() {
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.get('/', ok)
	app.listen('127.0.0.1:18099') or { panic(err) }
}
V
v -o "$BIN" /tmp/viltrum-bench-main.v
fuser -k 18099/tcp 2>/dev/null || true
"$BIN" >/tmp/viltrum-bench-srv.log 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 1 80); do
  if curl -sf "http://${ADDR}/" >/dev/null; then break; fi
  sleep 0.05
done

echo "== Viltrum bench ($(date -Iseconds)) =="
if command -v oha >/dev/null 2>&1; then
  oha -n 5000 -c 50 --no-tui "http://${ADDR}/" | tee /tmp/viltrum-bench-out.txt
else
  echo "oha not found; sequential curl (lower bound, not peak RPS)"
  N=1000
  START=$(date +%s%N)
  for _ in $(seq 1 "$N"); do
    curl -sf "http://${ADDR}/" >/dev/null
  done
  END=$(date +%s%N)
  MS=$(( (END - START) / 1000000 ))
  if [[ "$MS" -lt 1 ]]; then MS=1; fi
  RPS=$(( N * 1000 / MS ))
  echo "requests=${N} wall_ms=${MS} approx_rps=${RPS}" | tee /tmp/viltrum-bench-out.txt
fi
echo done
