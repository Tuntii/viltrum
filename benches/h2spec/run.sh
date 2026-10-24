#!/usr/bin/env bash
# Runs h2spec (HTTP/2 conformance, github.com/summerwind/h2spec) against
# benches/h2spec/main.v. Linux x86-64, V on PATH; h2spec is downloaded to /tmp.
# Expect 144 of 146 to pass: 3.5/2 sends a preface a listener that also serves
# HTTP/1.1 reads as an HTTP/1.1 request (see docs/http2.md).
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
"$bin" -h 127.0.0.1 -p 9002 -o 2 "$@" | sed -n '/^Failures/,$p'
