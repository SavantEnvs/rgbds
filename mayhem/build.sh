#!/usr/bin/env bash
#
# mayhem/build.sh — build RGBDS twice: sanitized fuzz binaries (build-mayhem/) and the normal
# binaries the upstream test suite drives (repo root, where test/*/test.sh looks for them).
# Runs in /mayhem as `mayhem`; offline-safe (apt libpng-dev + bison come from the image).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

BUILD=build-mayhem   # matches upstream's `build*/` .gitignore entry, so `git clean -ffdX` removes it
BINS="rgbasm rgblink rgbfix rgbgfx"

# 1) Sanitized fuzz build, in a private copy of the sources so its objects never mix with the
#    normal build below. Generated bison outputs and stale objects are not copied.
mkdir -p "$BUILD"
tar -c --exclude='*.o' \
    --exclude=src/asm/parser.cpp --exclude=src/asm/parser.hpp --exclude=src/asm/stack.hh \
    --exclude=src/link/script.cpp --exclude=src/link/script.hpp --exclude=src/link/stack.hh \
    src include Makefile | tar -x -C "$BUILD"

# LeakSanitizer off at build time (leaks are not the bug class fuzzed here); ASan/UBSan stay on.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$BUILD/lsan_off.o"

# No -DNDEBUG / LTO: keep upstream's asserts live in the fuzz build.
make -C "$BUILD" -j"$MAYHEM_JOBS" Q='' CC="$CC" CXX="$CXX" \
    CXXFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS" \
    LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $SRC/$BUILD/lsan_off.o" \
    $BINS

# 2) Normal build (upstream's own flags minus LTO) for the functional test suite.
make -j"$MAYHEM_JOBS" Q='' CC="$CC" CXX="$CXX" CXXFLAGS="-O2 -DNDEBUG $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
    $BINS test/gfx/randtilegen test/gfx/rgbgfx_test

for b in $BINS; do
  [ -x "$BUILD/$b" ] && [ -x "$b" ] || { echo "build.sh: missing $b" >&2; exit 1; }
done
