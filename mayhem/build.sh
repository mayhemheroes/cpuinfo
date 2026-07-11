#!/usr/bin/env bash
#
# cpuinfo/mayhem/build.sh — build pytorch/cpuinfo's OSS-Fuzz harness as a sanitized libFuzzer
# target (+ a standalone reproducer), AND cpuinfo's own gtest unit tests for mayhem/test.sh.
#
# Fuzzed surface: cpuinfo's Linux /proc/cpuinfo + sysfs topology PARSERS. The OSS-Fuzz harness
# (fuzz_cpuinfo.c) writes the input bytes to /tmp/libfuzzer.config, then calls:
#   cpuinfo_x86_linux_parse_proc_cpuinfo()   — parses an x86 /proc/cpuinfo blob
#   cpuinfo_linux_get_max_processors_count() — parses the sysfs kernel_max number file
# To make those read the fuzzer file instead of the real kernel paths, upstream's OSS-Fuzz build
# rewrites the hardcoded paths in src/x86/linux/cpuinfo.c and src/linux/processors.c. We replicate
# that here. NOTE: current upstream wraps the kernel_max path in a #define KERNEL_MAX_FILENAME, so
# the original OSS-Fuzz sed (which matched the bare literal) no longer hits — we patch the #define.
#
# Build contract from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/$OUT.
# We compile the cpuinfo library ITSELF with $SANITIZER_FLAGS so the parsers are instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS=-gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE OUT MAYHEM_JOBS

cd "$SRC"

# ── 0) Redirect the kernel paths the harness drives at /tmp/libfuzzer.config (OSS-Fuzz parity) ─────
# x86 /proc/cpuinfo path (still a bare literal upstream):
sed -i 's#"/proc/cpuinfo"#"/tmp/libfuzzer.config"#g' src/x86/linux/cpuinfo.c
# sysfs kernel_max path is now behind a #define — rewrite the #define value:
sed -i 's#define KERNEL_MAX_FILENAME "/sys/devices/system/cpu/kernel_max"#define KERNEL_MAX_FILENAME "/tmp/libfuzzer.config"#' src/linux/processors.c

# ── 1) Build the cpuinfo static library WITH sanitizers (the fuzzed parsers are instrumented) ──────
# CMake build, tests/mocks/benchmarks off (same knobs the OSS-Fuzz build uses). We inject the
# sanitizer flags into the C flags so libcpuinfo.a is instrumented.
#
# Coverage: the fuzzed PARSER lives in libcpuinfo, not the harness — so the library must carry
# SanitizerCoverage edges too, otherwise libFuzzer sees no features ("no interesting inputs ... Is
# the code instrumented?"). When fuzzing with libFuzzer (LIB_FUZZING_ENGINE = -fsanitize=fuzzer),
# compile the library with -fsanitize=fuzzer-no-link (coverage instrumentation, no libFuzzer main).
COV_FLAG=""
case "$LIB_FUZZING_ENGINE" in
  *-fsanitize=fuzzer*) COV_FLAG="-fsanitize=fuzzer-no-link" ;;
esac

BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAG" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAG" \
    -DCPUINFO_BUILD_UNIT_TESTS=OFF \
    -DCPUINFO_BUILD_MOCK_TESTS=OFF \
    -DCPUINFO_BUILD_BENCHMARKS=OFF \
    -DCPUINFO_BUILD_TOOLS=OFF \
    -DCMAKE_BUILD_TYPE=Debug
cmake --build "$BUILD" --target cpuinfo -j"$MAYHEM_JOBS"

LIBCPUINFO="$(find "$BUILD" -name 'libcpuinfo.a' | head -1)"
LIBCLOG="$(find "$BUILD" -name 'libclog.a' | head -1)"
[ -n "$LIBCPUINFO" ] || { echo "ERROR: libcpuinfo.a not built" >&2; exit 1; }
echo "libcpuinfo.a: $LIBCPUINFO"
echo "libclog.a:    ${LIBCLOG:-<none>}"

INC="-I$SRC/src -I$SRC/include"
HARNESS_DIR="$SRC/mayhem/harnesses"

# Standalone driver object (no libFuzzer runtime, reads one input file).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HARNESS_DIR/standalone_main.c" -o "$BUILD/standalone_main.o"

# ── 2) Build the harness twice: libFuzzer (-> $OUT/<name>) + standalone reproducer ────────────────
for harness in fuzz_cpuinfo; do
  # coverage-instrumented object for the libFuzzer target
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAG $INC -c "$HARNESS_DIR/$harness.c" -o "$BUILD/$harness.cov.o"
  # plain object for the standalone reproducer (no libFuzzer/coverage runtime to satisfy)
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC -c "$HARNESS_DIR/$harness.c" -o "$BUILD/$harness.o"

  # libFuzzer target -> $OUT/<name>
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$BUILD/$harness.cov.o" \
      "$LIBCPUINFO" ${LIBCLOG:+$LIBCLOG} -lpthread -o "$OUT/$harness"

  # standalone reproducer (no libFuzzer runtime) -> $OUT/<name>-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$BUILD/$harness.o" "$BUILD/standalone_main.o" \
      "$LIBCPUINFO" ${LIBCLOG:+$LIBCLOG} -lpthread -o "$OUT/$harness-standalone"

  echo "built $harness (+ standalone)"
done

# ── 3) Build cpuinfo's OWN gtest unit tests with NORMAL flags (clean, separate tree) so test.sh
#       only RUNS them. On a Linux/x86 host the self-contained data-replay tests that build are:
#       init-test, get-current-test, and brand-string-test (the recorded x86 brand-string
#       known-answer suite). cpuinfo links the bare `gtest`/`gtest_main` targets, so we feed it the
#       Debian googletest SOURCE (apt: googletest) via GOOGLETEST_SOURCE_DIR + USE_SYSTEM_GOOGLETEST=OFF
#       — that ADD_SUBDIRECTORYs the source (offline) and produces exactly those targets. ────────────
TESTS="$SRC/mayhem-tests"
GTEST_SRC=""
for d in /usr/src/googletest/googletest /usr/src/googletest /usr/src/gtest; do
  [ -f "$d/CMakeLists.txt" ] && { GTEST_SRC="$d"; break; }
done
rm -rf "$TESTS"; mkdir -p "$TESTS"
if [ -n "$GTEST_SRC" ] && cmake -S "$SRC" -B "$TESTS" \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCPUINFO_BUILD_UNIT_TESTS=ON \
      -DCPUINFO_BUILD_MOCK_TESTS=OFF \
      -DCPUINFO_BUILD_BENCHMARKS=OFF \
      -DCPUINFO_BUILD_TOOLS=OFF \
      -DUSE_SYSTEM_GOOGLETEST=OFF \
      -DGOOGLETEST_SOURCE_DIR="$GTEST_SRC" \
      -DCMAKE_BUILD_TYPE=Release > "$TESTS/cmake.log" 2>&1; then
  # Build whichever unit-test targets this platform defines.
  cmake --build "$TESTS" -j"$MAYHEM_JOBS" >> "$TESTS/build.log" 2>&1 \
    || echo "WARNING: some test targets failed to build (see mayhem-tests/build.log)" >&2
  echo "built cpuinfo unit tests in mayhem-tests/"
else
  echo "WARNING: test-suite cmake configure failed (mayhem/test.sh will report a failure)" >&2
  cat "$TESTS/cmake.log" >&2 || true
fi

echo "build.sh complete:"
ls -la "$OUT/fuzz_cpuinfo" "$OUT/fuzz_cpuinfo-standalone" 2>&1 || true
