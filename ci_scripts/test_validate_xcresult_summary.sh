#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures/xcresult-verdict"

"${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --summary-file "${FIXTURES}/passing.json" --suite passing --xcodebuild-exit 0
"${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --summary-file "${FIXTURES}/passing.json" --suite teardown-65 --xcodebuild-exit 65

expect_failure() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "error: ${name} unexpectedly passed" >&2
    exit 1
  fi
  echo "fixture=${name} result=failed-as-expected"
}

# The paired log ends with a restarted zero-test suite, but its canonical
# summary keeps the earlier failures and must reject the otherwise tolerated 65.
grep -Fq "Executed 0 tests, with 0 failures" "${FIXTURES}/trailing-zero-restart.log"
expect_failure trailing-zero-restart \
  "${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --summary-file "${FIXTURES}/trailing-zero-restart.json" --suite ui --xcodebuild-exit 65
expect_failure missing-result \
  "${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --result-bundle "${FIXTURES}/missing.xcresult" --suite missing --xcodebuild-exit 0
expect_failure malformed-result \
  "${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --summary-file "${FIXTURES}/malformed.json" --suite malformed --xcodebuild-exit 0
expect_failure canonical-failures \
  "${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --summary-file "${FIXTURES}/failed.json" --suite failed --xcodebuild-exit 0
expect_failure all-skipped \
  "${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --summary-file "${FIXTURES}/all-skipped.json" --suite skipped --xcodebuild-exit 0
expect_failure no-tests \
  "${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --summary-file "${FIXTURES}/no-tests.json" --suite empty --xcodebuild-exit 0
expect_failure unexpected-xcodebuild-exit \
  "${SCRIPT_DIR}/validate_xcresult_summary.py" \
  --summary-file "${FIXTURES}/passing.json" --suite process --xcodebuild-exit 1

echo "xcresult-verdict fixtures passed"
