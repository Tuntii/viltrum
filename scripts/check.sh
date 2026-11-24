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
	# examples that ship handler tests (handle_raw), e.g. todo_api
	if known_v_bug_alias_generic; then
		return
	fi
	for t in examples/*/*_test.v; do
		if [ -e "$t" ]; then v test "$(dirname "$t")/"; fi
	done
}

# known_v_bug_alias_generic: only in CI's V master job (VILTRUM_V_MASTER set). V master
# passes a copy as the receiver of a generic method called through an alias named like
# its struct (vlang/v#32402), so c.json through viltrum.Ctx answers 500 there and the
# example handler tests fail for V's reason, not viltrum's. While the probe still shows
# the bug they are skipped with a warning; once V is fixed they run again by themselves.
# A probe that does not build fails the job.
known_v_bug_alias_generic() {
	[ -n "${VILTRUM_V_MASTER:-}" ] || return 1
	probe=$(mktemp -d)
	# set -e does not reach into a function called as an if condition: fail by hand
	v -o "$probe/alias_generic" scripts/vbugs/alias_generic/ || {
		echo "scripts/vbugs/alias_generic did not build" >&2
		exit 1
	}
	if "$probe/alias_generic"; then
		rm -rf "$probe"
		return 1
	fi
	rm -rf "$probe"
	echo "::warning::V master still copies generic receivers through a same-name alias (vlang/v#32402): example handler tests skipped"
	return 0
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
