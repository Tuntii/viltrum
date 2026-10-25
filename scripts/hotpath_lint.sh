#!/usr/bin/env bash
# Fails when a hot-path file uses a construct that allocates per request. A line can
# opt out with a trailing "// cold:" comment explaining why it is off the hot path.
set -uo pipefail
files="http1/bytes.v http1/frame.v http1/chunked.v http1/parse.v http1/writer.v http1/date.v
http1/ctx.v http1/gzip.v http1/deflate.v http1/ws.v jsonenc/encode.v engine/process.v engine/timers.v engine/worker_linux.c.v
engine/tls_linux.c.v engine/ws.v engine/tls13_linux.c.v router/router.v http2/hpack.v http2/huffman.v http2/frame.v engine/h2.v
http1/stream.v engine/stream.v engine/h2_stream.v"
pattern='\$\{|\.str\(\)|\.split\(|\.to_lower\(|\.to_upper\(|\.trim|\.bytestr\(\)|\.clone\(\)|\[([^]]*[^. ])?\.\.[^]]*\]'
bad=0
for f in $files; do
	[ -f "$f" ] || { echo "missing: $f"; exit 1; }
	hits=$(grep -nE "$pattern" "$f" | grep -vE '^[0-9]+:\s*//' | grep -v '// cold:')
	if [ -n "$hits" ]; then
		echo "$f:"
		echo "$hits"
		bad=1
	fi
done
[ "$bad" = 0 ] && echo "hot path clean"
exit $bad
