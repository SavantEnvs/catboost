#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS the known-answer self-tests that mayhem/build.sh built with normal flags
# (/mayhem/catboost_selftest over util/cgiparam/json/http-io/base64/flat_hash, /mayhem/lz4_selftest over
# liblz4). Each prints `PASS <name>` / `FAIL <name>`; the counts become the CTRF report.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

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

# Number of PASS lines each binary must print; a binary that exits early (or prints nothing) fails the
# shortfall instead of passing vacuously.
EXPECTED_catboost_selftest=14
EXPECTED_lz4_selftest=8

passed=0
failed=0
for bin in catboost_selftest lz4_selftest; do
  if [ ! -x "$SRC/$bin" ]; then
    echo "missing $SRC/$bin (mayhem/build.sh should have built it)" >&2
    failed=$(( failed + 1 ))
    continue
  fi
  out="$("$SRC/$bin" 2>&1)"
  rc=$?
  echo "$out"
  p=$(printf '%s\n' "$out" | grep -c '^PASS ')
  f=$(printf '%s\n' "$out" | grep -c '^FAIL ')
  var="EXPECTED_$bin"
  want="${!var}"
  [ "$rc" -eq 0 ] || f=$(( f + 1 ))
  [ "$p" -ge "$want" ] || f=$(( f + want - p ))
  passed=$(( passed + p ))
  failed=$(( failed + f ))
done

emit_ctrf "catboost-selftest" "$passed" "$failed" 0
