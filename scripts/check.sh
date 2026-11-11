#!/usr/bin/env bash
# The checks CI runs, in one place. CI calls the `tests` and `examples` parts; run it
# with no argument before a pull request.
#   bash scripts/check.sh            everything this machine can run
#   bash scripts/check.sh tests      the unit tests
#   bash scripts/check.sh examples   build every example
set -euo pipefail
cd "$(dirname "$0")/.."

test_dirs="http1 http2 jsonenc router engine tests"

run_tests() {
	for d in $test_dirs; do
		v test "$d/"
	done
}

build_examples() {
	out=$(mktemp -d)
	for e in examples/*/; do
		name=$(basename "$e")
		v -o "$out/viltrum-$name" "examples/$name"
	done
	rm -rf "$out"
}

case "${1:-all}" in
tests) run_tests ;;
examples) build_examples ;;
all)
	v fmt -verify .
	run_tests
	v -d viltrum_debug test router/ engine/ tests/
	bash scripts/hotpath_lint.sh
	build_examples
	if [ "$(uname -s)" = Linux ]; then
		bash scripts/gcpin_check.sh
		if command -v gcc >/dev/null 2>&1; then
			v -cc gcc test engine/aesgcm_linux_test.v engine/tls13_linux_test.v engine/tls_linux_test.v engine/hs13_linux_test.v
			v -cc gcc test http1/deflate_test.v jsonenc/
		fi
	else
		echo "skipped (Linux only): gcpin_check, the gcc TLS tests; the engine's socket tests did not run"
	fi
	echo "all checks passed"
	;;
*)
	echo "usage: bash scripts/check.sh [tests|examples]" >&2
	exit 2
	;;
esac
