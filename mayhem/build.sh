#!/usr/bin/env bash
#
# mayhem/build.sh — builds, inside the commit image (as `mayhem`, in /mayhem):
#   * the sanitized fuzz binaries + run-once `-standalone` reproducers   -> /mayhem/<target>[-standalone]
#   * the project's known-answer self-tests with NORMAL flags (for test.sh) -> /mayhem/catboost_selftest, /mayhem/lz4_selftest
# catboost's CMake tree needs a JDK, SWIG, Cython and numpy to configure in full, so mayhem/cmake is a
# small wrapper project that configures only the library directories the harnesses link (dirs.txt).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS SRC

cd "$SRC"

CPP_TARGETS="fuzz_cgiparam fuzz_http_io fuzz_json fuzz_base64_roundtrip fuzz_base64_uneven fuzz_flat_hash_dense_map fuzz_flat_hash_flat_map fuzz_rb_tree"
LZ4_TARGETS="compress decompress round_trip round_trip_stream compress_hc round_trip_hc compress_frame round_trip_frame round_trip_frame_uncompressed decompress_frame"

# ragel and yasm are baked into the image (Dockerfile); catboost's CMake expects them under <build>/bin.
link_host_tools() {
  mkdir -p "$1/bin"
  for t in ragel yasm; do
    ln -sf "$(command -v "$t")" "$1/bin/$t"
  done
}

# ASan's leak check is off while the build runs host tools (enum_parser); the shipped fuzzers carry lsan_off.cc.
export ASAN_OPTIONS=detect_leaks=0

# 1) Sanitized catboost libraries + C++ harnesses. -fno-sanitize=vptr: UBSan's vptr check calls
#    __dynamic_cast, which catboost's bundled libcxxrt implements with a vptr-checked dynamic_cast
#    itself, so any instrumented binary overflows the stack on its first RTTI query.
FUZZ_FLAGS="$SANITIZER_FLAGS -fno-sanitize=vptr $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
CMAKE_BUILD="$SRC/mayhem/build-cmake"
link_host_tools "$CMAKE_BUILD"
rm -f "$CMAKE_BUILD/CMakeCache.txt"
CFLAGS="$FUZZ_FLAGS" CXXFLAGS="$FUZZ_FLAGS" LDFLAGS="$SANITIZER_FLAGS" \
  cmake -Wno-dev -G Ninja -S "$SRC/mayhem/cmake" -B "$CMAKE_BUILD" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_BUILD_TYPE=Release -DCUSTOM_ALLOCATORS=Off
targets=""
for t in $CPP_TARGETS; do targets="$targets $t $t-standalone"; done
# shellcheck disable=SC2086
ninja -C "$CMAKE_BUILD" -j"$MAYHEM_JOBS" $targets
for t in $CPP_TARGETS; do
  cp -f "$CMAKE_BUILD/$t" "$SRC/$t"
  cp -f "$CMAKE_BUILD/$t-standalone" "$SRC/$t-standalone"
done

# 2) lz4 (vendored copy under contrib/crates): upstream's OSS-Fuzz harnesses over its liblz4.
LZ4="$SRC/contrib/crates/lz4-sys-1.11.1+lz4-1.10.0/liblz4"
LZ4_OBJ="$SRC/mayhem/build-lz4"
mkdir -p "$LZ4_OBJ"
LZ4_CPP="-I$LZ4/lib -DXXH_NAMESPACE=LZ4_ -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DLZ4_DEBUG=1"
LZ4_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O2 -fsanitize=fuzzer-no-link"
for f in lz4 lz4hc lz4frame xxhash; do
  $CC $LZ4_CFLAGS $LZ4_CPP -c "$LZ4/lib/$f.c" -o "$LZ4_OBJ/$f.o"
done
for f in lz4_helpers fuzz_data_producer; do
  $CC $LZ4_CFLAGS $LZ4_CPP -c "$LZ4/ossfuzz/$f.c" -o "$LZ4_OBJ/$f.o"
done
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LZ4_OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$LZ4_OBJ/standalone_main.o"
LZ4_LIB_OBJS="$LZ4_OBJ/lz4.o $LZ4_OBJ/lz4hc.o $LZ4_OBJ/lz4frame.o $LZ4_OBJ/xxhash.o $LZ4_OBJ/lz4_helpers.o $LZ4_OBJ/fuzz_data_producer.o $LZ4_OBJ/lsan_off.o"
for t in $LZ4_TARGETS; do
  $CC $LZ4_CFLAGS $LZ4_CPP -c "$LZ4/ossfuzz/${t}_fuzzer.c" -o "$LZ4_OBJ/${t}_fuzzer.o"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$LZ4_OBJ/${t}_fuzzer.o" $LZ4_LIB_OBJS -o "$SRC/fuzz_lz4_$t"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$LZ4_OBJ/${t}_fuzzer.o" $LZ4_LIB_OBJS "$LZ4_OBJ/standalone_main.o" -o "$SRC/fuzz_lz4_$t-standalone"
done

# 3) Test suite, normal flags (no sanitizers, no coverage engine): what test.sh runs.
TEST_BUILD="$SRC/mayhem/build-test"
link_host_tools "$TEST_BUILD"
rm -f "$TEST_BUILD/CMakeCache.txt"
CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
  env -u LIB_FUZZING_ENGINE -u STANDALONE_FUZZ_MAIN \
  cmake -Wno-dev -G Ninja -S "$SRC/mayhem/cmake" -B "$TEST_BUILD" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_BUILD_TYPE=Release -DCUSTOM_ALLOCATORS=Off
ASAN_OPTIONS= ninja -C "$TEST_BUILD" -j"$MAYHEM_JOBS" catboost_selftest
cp -f "$TEST_BUILD/catboost_selftest" "$SRC/catboost_selftest"
$CC -O2 $COVERAGE_FLAGS $LZ4_CPP -I"$LZ4/ossfuzz" "$SRC/mayhem/lz4_selftest.c" \
  "$LZ4/lib/lz4.c" "$LZ4/lib/lz4hc.c" "$LZ4/lib/lz4frame.c" "$LZ4/lib/xxhash.c" -o "$SRC/lz4_selftest"

echo "build.sh: done"
