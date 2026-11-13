#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# RUN upstream's own regression suites (test/{asm,link,fix,gfx}/test.sh, as test/run-tests.sh
# --only-internal does) against the normal (unsanitized) binaries build.sh left in the repo root.
# Each suite diffs the tools' output against golden files and ends in "All N tests passed!" or
# "F of the tests failed!"; that summary line is parsed, so a neutered binary (no output) is a failure.
export LC_ALL=C
export SOURCE_DATE_EPOCH=609165296   # Game Boy release date, for reproducible golden output
export TERM="${TERM:-dumb}"

for b in rgbasm rgblink rgbfix rgbgfx test/gfx/randtilegen test/gfx/rgbgfx_test; do
  [ -x "$SRC/$b" ] || { echo "test.sh: $b is missing — mayhem/build.sh should have built it" >&2; emit_ctrf "upstream-regression" 0 1 0; exit 1; }
done

passed=0 failed=0
for suite in asm link fix gfx; do
  out="$(cd "$SRC/test/$suite" && ./test.sh 2>&1)"
  echo "$out" | tail -n 5
  clean="$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b(B//g')"
  if n="$(printf '%s\n' "$clean" | sed -n 's/^All \([0-9][0-9]*\) tests passed!$/\1/p' | tail -n 1)" && [ -n "$n" ]; then
    passed=$(( passed + n ))
  elif f="$(printf '%s\n' "$clean" | sed -n 's/^\([0-9][0-9]*\) of the tests failed!$/\1/p' | tail -n 1)" && [ -n "$f" ]; then
    failed=$(( failed + f ))
  else
    echo "test.sh: no summary line from test/$suite" >&2
    failed=$(( failed + 1 ))
  fi
done

# Known-answer probe through the dynamically linked tools: assemble -> link -> fix a two-byte ROM
# and assert the exact bytes and header checksum, independent of the golden-file suites above.
probe() {
  local d; d="$(mktemp -d)"
  printf 'SECTION "kat", ROM0[$0]\n  db $12, $34\n' > "$d/kat.asm"
  if "$SRC/rgbasm" -o "$d/kat.o" "$d/kat.asm" \
     && "$SRC/rgblink" -o "$d/kat.gb" "$d/kat.o" \
     && [ "$(od -An -tx1 -N2 "$d/kat.gb" | tr -d ' \n')" = "1234" ] \
     && "$SRC/rgbfix" -v -p 0xFF -m ROM -t KAT "$d/kat.gb" \
     && [ "$(wc -c < "$d/kat.gb")" = "32768" ] \
     && [ "$(od -An -tx1 -j308 -N4 "$d/kat.gb" | tr -d ' \n')" = "4b415400" ]; then
    rm -rf "$d"; return 0
  fi
  rm -rf "$d"; return 1
}
if probe; then passed=$(( passed + 1 )); else echo "test.sh: assemble/link/fix known-answer probe failed" >&2; failed=$(( failed + 1 )); fi

emit_ctrf "rgbds-regression" "$passed" "$failed" 0
