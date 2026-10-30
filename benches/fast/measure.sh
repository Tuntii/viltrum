#!/usr/bin/env bash
# measure.sh REPO HASH WORK: measures one viltrum commit and prints one JSON line,
#   {"hash":..,"setup":..,"status":"ok|build_failed|run_failed","ir":{..},"rps":{..}}
# ir is callgrind instructions per request on one worker and one connection, so
# it does not move with machine noise; rps is a short run on 4 CPUs and is only
# roughly comparable. Logs go to stderr. Needs LOAD (the built load client).
# Exits 3 with no line when FAST_PORT is taken, so nothing is recorded.
# Changing anything that moves the numbers means bumping SETUP (README.md).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=${1:?usage: measure.sh REPO HASH WORK}
hash=$(git -C "$repo" rev-parse "${2:?usage: measure.sh REPO HASH WORK}")
work=${3:?usage: measure.sh REPO HASH WORK}
load=${LOAD:?LOAD must point at the built load client}
v=${V:-/root/v052/v/v}
data=${FAST_DATA:-/opt/viltrum-fast/data/dataset.json}
port=${FAST_PORT:-28090}
setup=$(tr -d '[:space:]' <"$here/SETUP")
d=$work/$hash
pid=

cleanup() {
	stop_server
	rm -rf "$d"
}
trap cleanup EXIT
trap 'exit 1' TERM INT # so a timeout still runs cleanup

emit() { # status [ir-json rps-json]
	if [ "$1" = ok ]; then
		printf '{"hash":"%s","setup":"%s","status":"ok","ir":%s,"rps":%s}\n' "$hash" "$setup" "$2" "$3"
	else
		printf '{"hash":"%s","setup":"%s","status":"%s"}\n' "$hash" "$setup" "$1"
	fi
	exit 0
}

# name, path, load flags: warmup count, measured count, extra flags
scenarios=(
	"baseline|/baseline11?a=1&b=2|500|20000|"
	"json|/json/50?m=1|100|2000|-H Accept-Encoding: gzip"
	"pipelined|/pipeline|500|20000|-p 16"
)

run_load() { # cpus (or ""), path, -n|-d, value, scenario flags, more load flags...
	local cpus=$1 path=$2 mode=$3 val=$4 extra=$5
	shift 5
	local args=(127.0.0.1 "$port" "$path" "$@" "$mode" "$val") pin=()
	case $extra in
	"-H "*) args+=(-H "${extra#-H }") ;;
	?*) read -ra more <<<"$extra" && args+=("${more[@]}") ;;
	esac
	[ -n "$cpus" ] && pin=(taskset -c "$cpus")
	"${pin[@]}" "$load" "${args[@]}"
}

wait_ready() { # seconds
	for _ in $(seq $(($1 * 10))); do
		"$load" 127.0.0.1 "$port" /pipeline -n 1 >/dev/null 2>&1 && return 0
		kill -0 "$pid" 2>/dev/null || return 1
		sleep 0.1
	done
	return 1
}

# stop_server asks for viltrum's graceful stop and kills it if that hangs.
stop_server() {
	[ -n "$pid" ] || return 0
	kill "$pid" 2>/dev/null
	for _ in $(seq 50); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	kill -9 "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	pid=
}

mkdir -p "$d/vm/viltrum"
git -C "$repo" archive "$hash" | tar -x -C "$d/vm/viltrum" || emit build_failed
echo "building $hash" >&2
VMODULES=$d/vm VCACHE=${VCACHE:-$work/.vcache} "$v" -prod -o "$d/server" "$here/server.v" >"$d/build.log" 2>&1 || {
	tail -20 "$d/build.log" >&2
	emit build_failed
}

# a taken port says nothing about the commit: no result, exit 3, run.sh retries later
if ss -Hltn "sport = :$port" | grep -q .; then
	echo "port $port is taken" >&2
	exit 3
fi

# Ir/request: one worker on one CPU under callgrind, one connection.
FAST_ADDR=127.0.0.1:$port FAST_DATA=$data VILTRUM_WORKERS=1 \
	taskset -c 0 valgrind --tool=callgrind --callgrind-out-file="$d/cg.out" "$d/server" 2>"$d/valgrind.log" &
pid=$!
wait_ready 60 || { echo "server did not come up under valgrind" >&2; emit run_failed; }
ir=
for s in "${scenarios[@]}"; do
	IFS='|' read -r name path warm n extra <<<"$s"
	run_load "" "$path" -n "$warm" "$extra" -c 1 >/dev/null || emit run_failed
	callgrind_control -z "$pid" >/dev/null || emit run_failed
	line=$(run_load "" "$path" -n "$n" "$extra" -c 1) || { echo "$line" >&2; emit run_failed; }
	before=$(ls "$d"/cg.out.* 2>/dev/null | wc -l)
	callgrind_control -d "$pid" >/dev/null || emit run_failed
	dump=$(ls -t "$d"/cg.out.* 2>/dev/null | head -1)
	[ "$(ls "$d"/cg.out.* 2>/dev/null | wc -l)" -gt "$before" ] || emit run_failed
	total=$(awk '/^(summary|totals):/ {print $2; exit}' "$dump")
	[ -n "$total" ] || emit run_failed
	per=$(((total + n / 2) / n))
	echo "$name: $per Ir/request" >&2
	ir="$ir\"$name\":$per,"
done
stop_server

# rps: 4 workers on CPUs 0-3, the client on 4-7, median of three 3 s runs.
FAST_ADDR=127.0.0.1:$port FAST_DATA=$data VILTRUM_WORKERS=4 taskset -c 0-3 "$d/server" 2>/dev/null &
pid=$!
wait_ready 10 || emit run_failed
rps=
for s in "${scenarios[@]}"; do
	IFS='|' read -r name path warm n extra <<<"$s"
	run_load 4-7 "$path" -d 1 "$extra" -c 64 >/dev/null || emit run_failed
	runs=()
	for _ in 1 2 3; do
		line=$(run_load 4-7 "$path" -d 3 "$extra" -c 64) || emit run_failed
		runs+=("$(sed -n 's/.* rps=\([0-9]*\).*/\1/p' <<<"$line")")
	done
	med=$(printf '%s\n' "${runs[@]}" | sort -n | sed -n 2p)
	echo "$name: ~$med rps" >&2
	rps="$rps\"$name\":$med,"
done
stop_server

emit ok "{${ir%,}}" "{${rps%,}}"
