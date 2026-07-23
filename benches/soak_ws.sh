#!/usr/bin/env bash
# HTTP-adjacent WebSocket soak / close-storm harness (issue #5).
# Correctness + process liveness — not a throughput claim.
#
# Usage:
#   bash benches/soak_ws.sh
# Env (optional):
#   PORT=18086
#   CLIENTS=32          # concurrent echo clients
#   MSGS=100            # messages per client
#   CLOSE_ROUNDS=200    # rapid open/close cycles
#   SOAK_SECONDS=0      # extra multi-minute soak (0 = skip; CI-friendly)
#   PAYLOAD_SIZE=64
set -euo pipefail
export PATH="${HOME}/.local/bin:/tmp/v:${PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ln -sfn "$ROOT" "${HOME}/.vmodules/viltrum"

PORT="${PORT:-18086}"
CLIENTS="${CLIENTS:-32}"
MSGS="${MSGS:-100}"
CLOSE_ROUNDS="${CLOSE_ROUNDS:-200}"
SOAK_SECONDS="${SOAK_SECONDS:-0}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-64}"
BIN="/tmp/viltrum-ws-soak-bin"
OUT_DIR="/tmp/viltrum-bench"
mkdir -p "$OUT_DIR"

if ! command -v v >/dev/null 2>&1; then
	echo "v not on PATH" >&2
	exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
	echo "python3 required for WS soak client" >&2
	exit 2
fi

cat > /tmp/viltrum-ws-soak-main.v <<'V'
module main

import time
import viltrum

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: false
		max_conns:      10000
		read_timeout:   30 * time.second
		write_timeout:  30 * time.second
		idle_timeout:   60 * time.second
	})
	app.get('/health', fn (req viltrum.Request) viltrum.Response {
		return viltrum.text(200, 'ok')
	})
	app.ws('/ws', fn (mut s viltrum.WsSocket) {
		for {
			msg := s.read_message() or { break }
			if msg.is_text() {
				s.write_text(msg.text()) or { break }
			} else if msg.is_binary() {
				s.write_binary(msg.data) or { break }
			}
		}
		s.close_quiet()
	})
	app.listen('127.0.0.1:18086') or { panic(err) }
}
V

# Patch port into generated server if non-default
if [ "$PORT" != "18086" ]; then
	sed -i "s/127.0.0.1:18086/127.0.0.1:${PORT}/" /tmp/viltrum-ws-soak-main.v
fi

echo "== build soak server =="
v -o "$BIN" /tmp/viltrum-ws-soak-main.v

fuser -k "${PORT}/tcp" 2>/dev/null || true
"$BIN" >/tmp/viltrum-ws-soak-srv.log 2>&1 &
SRV_PID=$!
cleanup() {
	kill "$SRV_PID" 2>/dev/null || true
	wait "$SRV_PID" 2>/dev/null || true
	fuser -k "${PORT}/tcp" 2>/dev/null || true
}
trap cleanup EXIT

sleep 0.4
if ! kill -0 "$SRV_PID" 2>/dev/null; then
	echo "server died; log:" >&2
	cat /tmp/viltrum-ws-soak-srv.log >&2 || true
	exit 1
fi

# Quick HTTP health
if ! curl -fsS "http://127.0.0.1:${PORT}/health" | grep -q ok; then
	echo "health check failed" >&2
	exit 1
fi

export PORT CLIENTS MSGS CLOSE_ROUNDS SOAK_SECONDS PAYLOAD_SIZE
python3 - <<'PY' | tee "$OUT_DIR/ws_soak.json"
import base64, json, os, socket, struct, sys, time, concurrent.futures

PORT = int(os.environ["PORT"])
CLIENTS = int(os.environ["CLIENTS"])
MSGS = int(os.environ["MSGS"])
CLOSE_ROUNDS = int(os.environ["CLOSE_ROUNDS"])
SOAK_SECONDS = int(os.environ["SOAK_SECONDS"])
PAYLOAD_SIZE = int(os.environ["PAYLOAD_SIZE"])
payload = b"x" * PAYLOAD_SIZE


def mask_frame(opcode, body):
    mask = os.urandom(4)
    plen = len(body)
    b0 = opcode | 0x80
    if plen < 126:
        hdr = bytes([b0, 0x80 | plen])
    elif plen <= 65535:
        hdr = bytes([b0, 0x80 | 126]) + struct.pack("!H", plen)
    else:
        hdr = bytes([b0, 0x80 | 127]) + struct.pack("!Q", plen)
    masked = bytes(body[i] ^ mask[i % 4] for i in range(plen))
    return hdr + mask + masked


def recvn(sock, n):
    data = b""
    while len(data) < n:
        c = sock.recv(n - len(data))
        if not c:
            raise ConnectionError("eof")
        data += c
    return data


def read_frame(sock):
    hdr = recvn(sock, 2)
    op = hdr[0] & 0x0F
    plen = hdr[1] & 0x7F
    if plen == 126:
        plen = struct.unpack("!H", recvn(sock, 2))[0]
    elif plen == 127:
        plen = struct.unpack("!Q", recvn(sock, 8))[0]
    if hdr[1] & 0x80:
        recvn(sock, 4)
    return op, recvn(sock, plen)


def open_ws(timeout=10):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ).encode()
    s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.settimeout(timeout)
    s.sendall(req)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(4096)
        if not chunk:
            raise ConnectionError("eof during handshake")
        data += chunk
    if b"101" not in data.split(b"\r\n", 1)[0]:
        raise RuntimeError(f"handshake failed: {data[:200]!r}")
    return s


def close_ws(s):
    try:
        s.sendall(mask_frame(0x8, struct.pack("!H", 1000)))
    except Exception:
        pass
    try:
        s.close()
    except Exception:
        pass


def echo_worker(_):
    s = open_ws()
    ok = 0
    try:
        for _ in range(MSGS):
            s.sendall(mask_frame(0x1, payload))
            op, data = read_frame(s)
            if op == 1 and data == payload:
                ok += 1
            else:
                raise RuntimeError(f"echo mismatch op={op} len={len(data)}")
    finally:
        close_ws(s)
    return ok


def close_storm_once(_):
    s = open_ws(timeout=5)
    close_ws(s)
    return 1


out = {"ok": True, "errors": []}

# 1) Concurrent echo correctness
t0 = time.perf_counter()
with concurrent.futures.ThreadPoolExecutor(max_workers=CLIENTS) as ex:
    rows = list(ex.map(echo_worker, range(CLIENTS)))
echo_wall = time.perf_counter() - t0
echo_ok = sum(rows)
expected = CLIENTS * MSGS
if echo_ok != expected:
    out["ok"] = False
    out["errors"].append(f"echo mismatch: {echo_ok}/{expected}")
out["echo"] = {
    "clients": CLIENTS,
    "msgs_per_client": MSGS,
    "ok_msgs": echo_ok,
    "expected": expected,
    "wall_seconds": echo_wall,
}

# 2) Close storm: many open/close cycles
t0 = time.perf_counter()
with concurrent.futures.ThreadPoolExecutor(max_workers=min(64, CLOSE_ROUNDS)) as ex:
    closes = list(ex.map(close_storm_once, range(CLOSE_ROUNDS)))
close_wall = time.perf_counter() - t0
if sum(closes) != CLOSE_ROUNDS:
    out["ok"] = False
    out["errors"].append(f"close storm incomplete: {sum(closes)}/{CLOSE_ROUNDS}")
out["close_storm"] = {
    "rounds": CLOSE_ROUNDS,
    "ok": sum(closes),
    "wall_seconds": close_wall,
}

# Server still alive?
if not os.path.exists(f"/proc/{os.environ.get('SRV_PID', '')}"):
    # Parent exports via env only if set; check TCP health instead
    pass
try:
    s = open_ws()
    close_ws(s)
    out["server_alive_after_storm"] = True
except Exception as e:
    out["ok"] = False
    out["server_alive_after_storm"] = False
    out["errors"].append(f"server dead after storm: {e}")

# 3) Optional soak
if SOAK_SECONDS > 0:
    end = time.time() + SOAK_SECONDS
    soak_ok = 0
    soak_err = 0
    while time.time() < end:
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, CLIENTS)) as ex:
                rows = list(ex.map(echo_worker, range(min(16, CLIENTS))))
            soak_ok += sum(rows)
        except Exception as e:
            soak_err += 1
            out["errors"].append(f"soak error: {e}")
            out["ok"] = False
            break
    out["soak"] = {
        "seconds": SOAK_SECONDS,
        "ok_msgs": soak_ok,
        "errors": soak_err,
    }

print(json.dumps(out, indent=2))
if not out["ok"]:
    sys.exit(1)
print("soak_ws: PASS", file=sys.stderr)
PY

echo
echo "Raw JSON: $OUT_DIR/ws_soak.json"
echo "done"
