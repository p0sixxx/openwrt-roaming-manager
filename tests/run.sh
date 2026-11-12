#!/bin/sh
# roamctl test runner
#   tests/run.sh [--busybox] [--filter PATTERN] [suite...]
# Suites: unit integration regression (default: all)
# Every test_* function runs in its own subshell with a fresh fixture.

ORM_REPO=$(cd "$(dirname "$0")/.." && pwd)
export ORM_REPO
SYS_PATH=$PATH
export SYS_PATH
TEST_SH=${TEST_SH:-sh}
BB_BIN=''
FILTER=''
SUITES=''
while [ $# -gt 0 ]; do
	case "$1" in
	--busybox)
		command -v busybox >/dev/null || { echo "busybox not installed" >&2; exit 2; }
		BB_BIN="${TMPDIR:-/tmp}/roamctl-bb.$$"
		mkdir -p "$BB_BIN"
		for a in $(busybox --list); do ln -sf "$(command -v busybox)" "$BB_BIN/$a"; done
		TEST_SH="busybox ash"
		;;
	--filter) FILTER=$2; shift ;;
	-v) TEST_DEBUG=1; export TEST_DEBUG ;;
	*) SUITES="$SUITES $1" ;;
	esac
	shift
done
export BB_BIN TEST_SH
[ -n "$SUITES" ] || SUITES="unit integration regression"

pass=0 failn=0 failed_list=''
start=$(date +%s)
for suite in $SUITES; do
	for f in "$ORM_REPO/tests/$suite"/*.sh; do
		[ -f "$f" ] || continue
		tests=$(sed -n 's/^\(test_[A-Za-z0-9_]*\)[[:space:]]*()[[:space:]]*{.*/\1/p' "$f")
		for t in $tests; do
			[ -n "$FILTER" ] && ! printf '%s' "$suite/$(basename "$f" .sh)/$t" | grep -q -- "$FILTER" && continue
			printf '%-70s ' "$suite/$(basename "$f" .sh)/$t"; ts=$(date +%s)
			log="${TMPDIR:-/tmp}/roamctl-test-log.$$"
			(
				. "$ORM_REPO/tests/lib/testlib.sh"
				# shellcheck disable=SC1090
				. "$f"
				MOCK_ALIVE_PID=$$
				export MOCK_ALIVE_PID
				TEST_FAILS=0
				"$t"
				r=$?
				fx_cleanup
				[ "$TEST_FAILS" -eq 0 ] && [ "$r" -eq 0 ]
			) >"$log" 2>&1
			if [ $? -eq 0 ]; then
				echo "PASS ($(( $(date +%s) - ts ))s)"
				pass=$((pass + 1))
			else
				echo "FAIL ($(( $(date +%s) - ts ))s)"
				grep 'ASSERTION FAILED' "$log" | cut -c1-600 | sed 's/^/    | /'
				grep -v 'ASSERTION FAILED' "$log" | tail -n 12 | sed 's/^/    | /'
				failn=$((failn + 1))
				failed_list="$failed_list $suite/$(basename "$f" .sh)/$t"
			fi
			rm -f "$log"
		done
	done
done
[ -n "$BB_BIN" ] && rm -rf "$BB_BIN"
echo
echo "Shell: $TEST_SH$([ -n "$BB_BIN" ] && echo ' (BusyBox applets)')  Passed: $pass  Failed: $failn  Time: $(( $(date +%s) - start ))s"
if [ "$failn" -gt 0 ]; then
	for t in $failed_list; do echo "  FAILED: $t"; done
	exit 1
fi
exit 0
