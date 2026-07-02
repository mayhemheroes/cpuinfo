#!/usr/bin/env bash
#
# cpuinfo/mayhem/test.sh — RUN pytorch/cpuinfo's own gtest unit tests (built by mayhem/build.sh with
# normal flags) and emit a CTRF summary. exit 0 iff no test failed.
#
# Behavioral oracle — REWARD-HACK resistant (§6.3):
# We run the brand-string-test binary DIRECTLY (not via ctest) and assert that its stdout contains
# gtest's real output: a "[  PASSED  ] N test" line with N > 0. A neutered binary (LD_PRELOAD
# exit(0)) exits immediately with NO stdout, so grep fails and the test is counted as failed.
# ctest exit-code-only oracles pass the sabotage; output-grep does not.
#
# brand-string-test is a self-contained KNOWN-ANSWER suite — it feeds hundreds of recorded x86 brand
# strings to cpuinfo_x86_normalize_brand_string() and asserts the exact normalized output (EXPECT_EQ).
# It replays recorded data, needs no live hardware, and a no-op patch to the parser changes those
# outputs and fails. init-test / get-current-test query real /proc/cpuinfo and are NOT used here.
#
# This script only RUNS the pre-built binaries; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "gtest" 0 1 0; exit 2
fi

# Locate the brand-string-test binary (built under mayhem-tests/test/name/).
BSTEST=""
for candidate in \
    "$BUILDDIR/test/name/brand-string-test" \
    "$BUILDDIR/brand-string-test"; do
  [ -x "$candidate" ] && { BSTEST="$candidate"; break; }
done
if [ -z "$BSTEST" ]; then
  echo "ERROR: brand-string-test binary not found in $BUILDDIR" >&2
  echo "  (unit-test build may have failed; see mayhem-tests/build.log)" >&2
  emit_ctrf "gtest" 0 1 0; exit 1
fi

echo "=== running $BSTEST ==="
bsout="$("$BSTEST" 2>&1)"; bs_rc=$?
echo "$bsout"

# Behavioral assertion: gtest prints "[  PASSED  ] N test(s)." to stdout.
# A neutered-exit(0) binary produces NO output, so this grep fails.
# We also require at least one test actually reported.
passed_line="$(printf '%s\n' "$bsout" | grep -E '^\[  PASSED  \] [0-9]+ test')" || true
failed_line="$(printf '%s\n' "$bsout" | grep -E '^\[  FAILED  \] [0-9]+ test')" || true

if [ -z "$passed_line" ] && [ -z "$failed_line" ]; then
  echo "ERROR: brand-string-test produced no gtest summary output — binary may be neutered or crashed before running" >&2
  emit_ctrf "gtest" 0 1 0; exit 1
fi

# Parse pass/fail counts from gtest output.
N_PASS=0
N_FAIL=0
if [ -n "$passed_line" ]; then
  N_PASS="$(printf '%s\n' "$passed_line" | sed -n 's/\[  PASSED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)"
  : "${N_PASS:=0}"
fi
if [ -n "$failed_line" ]; then
  N_FAIL="$(printf '%s\n' "$failed_line" | sed -n 's/\[  FAILED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)"
  : "${N_FAIL:=0}"
fi

# Also honor the binary's exit code: a non-zero exit even with passing output means failure.
if [ "$bs_rc" -ne 0 ] && [ "$N_FAIL" -eq 0 ]; then
  N_FAIL=1
fi

# Sanity: require at least one test to have been reported (guards against an empty suite).
TOTAL=$(( N_PASS + N_FAIL ))
if [ "$TOTAL" -eq 0 ]; then
  echo "ERROR: brand-string-test reported 0 tests — expected a non-empty suite" >&2
  emit_ctrf "gtest" 0 1 0; exit 1
fi

emit_ctrf "gtest" "$N_PASS" "$N_FAIL" 0
