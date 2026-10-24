#!/usr/bin/env bash
# Runs h2spec (HTTP/2 conformance, github.com/summerwind/h2spec) against
# benches/h2spec/main.v, over TLS and in cleartext. Linux x86-64, V on PATH; h2spec
# is downloaded to /tmp. Expect 145 of 146 over TLS and 144 in cleartext, where
# 3.5/2 sends a preface a listener that also serves HTTP/1.1 reads as an HTTP/1.1
# request (see docs/http2.md). Extra arguments go to h2spec.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ver=2.6.0
bin=/tmp/h2spec-$ver/h2spec
if [ ! -x "$bin" ]; then
	mkdir -p "$(dirname "$bin")"
	curl -fsSL "https://github.com/summerwind/h2spec/releases/download/v$ver/h2spec_linux_amd64.tar.gz" |
		tar xz -C "$(dirname "$bin")"
fi
v -prod -o /tmp/viltrum-h2spec "$here"
/tmp/viltrum-h2spec &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
sleep 1
echo "== over TLS (ALPN h2)"
"$bin" -t -k -h 127.0.0.1 -p 9003 -o 2 "$@" | sed -n '/^Failures/,$p'
echo "== cleartext (prior knowledge)"
"$bin" -h 127.0.0.1 -p 9002 -o 2 "$@" | sed -n '/^Failures/,$p'
