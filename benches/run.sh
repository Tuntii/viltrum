#!/usr/bin/env bash
# Honest throughput smoke via oha (or curl fallback).
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
	app.options(viltrum.ServerOptions{ handle_signals: false })
	app.use(viltrum.recover)
	app.get('/', ok)
	app.listen('127.0.0.1:18099') or { panic(err) }
}
V
v -o "$BIN" /tmp/viltrum-bench-main.v

python3 - <<'PY'
import os, signal, subprocess, time, pathlib
env = os.environ.copy()
env["PATH"] = os.path.expanduser("~/.local/bin") + ":" + env.get("PATH", "")
subprocess.run(["fuser", "-k", "18099/tcp"], capture_output=True)
srv = subprocess.Popen([os.environ.get("BIN", "/tmp/viltrum-bench-bin")], start_new_session=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(80):
        if subprocess.run(["curl", "-sf", "http://127.0.0.1:18099/"], capture_output=True).returncode == 0:
            break
        time.sleep(0.05)
    else:
        raise SystemExit("server failed to start")
    print("== Viltrum bench ==")
    if subprocess.run(["bash", "-lc", "command -v oha"], capture_output=True).returncode == 0:
        p = subprocess.run(["oha", "-n", "10000", "-c", "100", "--no-tui", "http://127.0.0.1:18099/"],
                           capture_output=True, text=True, env=env)
        print(p.stdout)
        pathlib.Path("/tmp/viltrum-bench-out.txt").write_text(p.stdout)
    else:
        print("oha missing; install from https://github.com/hatoo/oha/releases")
        raise SystemExit(2)
finally:
    try:
        os.killpg(srv.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
print("done")
PY
