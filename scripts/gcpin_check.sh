#!/usr/bin/env bash
# Fails when viltrum's hot path carries V's Boehm scope pins. V 0.5.2 -prod builds
# wrap each call statement in a walk over every by-value struct or array of pointers
# in scope, and past 32 pointers take the global GC lock: invisible to the
# zero-allocation gate, but it serialized all workers. See jsonenc.encode_into.
# Usage: bash scripts/gcpin_check.sh   (needs v on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# The HttpArena entry instantiates Ctx.json and the encoder on nested structs and arrays.
v -prod -o "$out/probe.c" benches/httparena/main.v
# cold: startup, route registration, and the once-a-second TLS reload check
allow='^(viltrum__engine__serve|viltrum__engine__serve_listeners|viltrum__engine__run_worker|viltrum__engine__new_tls_server|viltrum__engine__TlsServer_reload|viltrum__App_[a-z_]+|viltrum__new)$'
bad=$(awk '
	/^[A-Za-z_].*\) \{$/ {
		fn = $0
		sub(/\(.*/, "", fn)
		n = split(fn, w, " ")
		fn = w[n]
	}
	/__v_boehm_collect_keepalive_/ && fn ~ /^viltrum__/ && fn !~ /^__v_boehm/ { hits[fn]++ }
	END { for (f in hits) print f }
' "$out/probe.c" | grep -Ev "$allow" || true)
if [ -n "$bad" ]; then
	echo "GC scope pins in the hot path (write the call as \`_ = f()\` or keep aggregates behind pointers):"
	echo "$bad"
	exit 1
fi
echo "no GC scope pins"
