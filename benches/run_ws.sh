#!/usr/bin/env bash
# WebSocket echo throughput (Python client). Honest laptop numbers; not TechEmpower.
set -euo pipefail
export PATH="${HOME}/.local/bin:/tmp/v:${PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ln -sfn "$ROOT" "${HOME}/.vmodules/viltrum"

PORT=18085
BIN="/tmp/viltrum-ws-bench-bin"
OUT_DIR="/tmp/viltrum-bench"
mkdir -p "$OUT_DIR"

if ! command -v v >/dev/null 2>&1; then
	echo "v not on PATH" >&2
	exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
	echo "python3 required for WS client" >&2
	exit 2
fi

cat > /tmp/viltrum-ws-bench-main.v <<'V'
module main

import time
import viltrum

fn main() {
	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: false
		max_conns:      10000
		read_timeout:   120 * time.second
		write_timeout:  120 * time.second
		idle_timeout:   120 * time.second
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
	app.listen('127.0.0.1:18085') or { panic(err) }
}
V

echo "== build WS echo (-prod) =="
if v -prod -o "$BIN" /tmp/viltrum-ws-bench-main.v 2>/tmp/viltrum-ws-bench-build.err; then
	echo "built with -prod → $BIN"
else
	echo "(-prod failed, using default build)"
	v -o "$BIN" /tmp/viltrum-ws-bench-main.v
fi

fuser -k "${PORT}/tcp" 2>/dev/null || true
"$BIN" >/tmp/viltrum-ws-bench-srv.log 2>&1 &
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
	cat /tmp/viltrum-ws-bench-srv.log >&2 || true
	exit 1
fi

python3 - <<'PY' | tee "$OUT_DIR/ws_results.json"
import base64, json, os, socket, struct, time, concurrent.futures

PORT = 18085

def mask_frame(opcode, payload):
	mask = os.urandom(4)
	plen = len(payload)
	b0 = opcode | 0x80
	if plen < 126:
		hdr = bytes([b0, 0x80 | plen])
	elif plen <= 65535:
		hdr = bytes([b0, 0x80 | 126]) + struct.pack("!H", plen)
	else:
		hdr = bytes([b0, 0x80 | 127]) + struct.pack("!Q", plen)
	masked = bytes(payload[i] ^ mask[i % 4] for i in range(plen))
	return hdr + mask + masked

def read_frame(sock):
	def recvn(n):
		data = b""
		while len(data) < n:
			c = sock.recv(n - len(data))
			if not c:
				raise ConnectionError("eof")
			data += c
		return data

	hdr = recvn(2)
	op = hdr[0] & 0x0F
	plen = hdr[1] & 0x7F
	if plen == 126:
		plen = struct.unpack("!H", recvn(2))[0]
	elif plen == 127:
		plen = struct.unpack("!Q", recvn(8))[0]
	if hdr[1] & 0x80:
		recvn(4)
	return op, recvn(plen)

def open_ws():
	key = base64.b64encode(os.urandom(16)).decode()
	req = (
		f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nUpgrade: websocket\r\n"
		f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
	).encode()
	s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
	s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
	s.sendall(req)
	data = b""
	while b"\r\n\r\n" not in data:
		data += s.recv(4096)
	if b"101" not in data.split(b"\r\n", 1)[0]:
		raise RuntimeError(data[:200])
	return s

def worker(n_msgs, payload):
	s = open_ws()
	t0 = time.perf_counter()
	ok = 0
	for _ in range(n_msgs):
		s.sendall(mask_frame(0x1, payload))
		op, data = read_frame(s)
		if op == 1 and data == payload:
			ok += 1
		else:
			break
	dt = time.perf_counter() - t0
	try:
		s.sendall(mask_frame(0x8, struct.pack("!H", 1000)))
		s.close()
	except Exception:
		pass
	return ok, dt

out = {}
payload64 = b"x" * 64
worker(100, payload64)  # warm

ok, dt = worker(20000, payload64)
out["A_single_20k_64B"] = {"ok": ok, "msg_s": ok / dt, "seconds": dt}

n_per, clients = 5000, 32
t0 = time.perf_counter()
with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as ex:
	rows = list(ex.map(lambda _: worker(n_per, payload64), range(clients)))
wall = time.perf_counter() - t0
oks = sum(r[0] for r in rows)
out["B_32conn_5k_each_64B"] = {
	"total_msgs": oks,
	"expected": clients * n_per,
	"success_rate": oks / (clients * n_per),
	"aggregate_msg_s": oks / wall,
	"wall_seconds": wall,
}

n_per, clients = 1000, 100
t0 = time.perf_counter()
with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as ex:
	rows = list(ex.map(lambda _: worker(n_per, payload64), range(clients)))
wall = time.perf_counter() - t0
oks = sum(r[0] for r in rows)
out["C_100conn_1k_each_64B"] = {
	"total_msgs": oks,
	"expected": clients * n_per,
	"success_rate": oks / (clients * n_per),
	"aggregate_msg_s": oks / wall,
	"wall_seconds": wall,
}

payload1k = b"y" * 1024
ok, dt = worker(5000, payload1k)
out["D_single_5k_1KB"] = {
	"ok": ok,
	"msg_s": ok / dt,
	"MB_s_rx_tx": ok * 1024 * 2 / dt / 1e6,
	"seconds": dt,
}

print(json.dumps(out, indent=2))
PY

echo
echo "Raw JSON: $OUT_DIR/ws_results.json"
echo "done"
