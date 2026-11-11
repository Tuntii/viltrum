#!/usr/bin/env bash
# smoke.sh VMODULES_DIR DATASET: builds the load client and the bench server
# against the viltrum in VMODULES_DIR, sends a fixed number of requests per
# scenario and fails unless every response came back.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
vm=${1:?usage: smoke.sh VMODULES_DIR DATASET}
data=${2:?usage: smoke.sh VMODULES_DIR DATASET}
v=${V:-/root/v052/v/v}
port=${FAST_PORT:-28091} # not 28090: measure.sh owns that, and viltrum binds with SO_REUSEPORT
out=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$out"' EXIT

gcc -O2 -Wall -o "$out/load" "$here/load.c"
VMODULES=$vm "$v" -prod -o "$out/server" "$here/server.v"

FAST_ADDR=127.0.0.1:$port FAST_DATA=$data VILTRUM_WORKERS=1 "$out/server" &
pid=$!
for _ in $(seq 50); do
	"$out/load" 127.0.0.1 "$port" /pipeline -n 1 >/dev/null 2>&1 && break
	sleep 0.1
done

check() { # n, then load arguments
	local n=$1
	shift
	local line
	line=$("$out/load" 127.0.0.1 "$port" "$@")
	echo "$* -> $line"
	[[ $line == "requests=$n errors=0 "* ]] || { echo "FAIL: want requests=$n errors=0" >&2; exit 1; }
}
check 1000 '/baseline11?a=1&b=2' -c 1 -n 1000
check 1600 /pipeline -c 1 -p 16 -n 1600
check 200 '/json/50?m=1' -c 1 -n 200 -H 'Accept-Encoding: gzip'
check 4000 '/baseline11?a=1&b=2' -c 8 -n 4000
echo smoke ok
