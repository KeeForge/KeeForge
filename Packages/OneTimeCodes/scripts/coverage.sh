#!/usr/bin/env bash
# Runs the OneTimeCodes tests with coverage and enforces line, region, and function
# thresholds over Sources/OneTimeCodes. Swift emits no llvm-cov branch records, so
# region coverage (every if/guard/switch arm and short-circuit) is the branch
# measure.
#
# Usage: scripts/coverage.sh [--show-uncovered] [--skip-tests]
# Thresholds (percent): ONETIMECODES_MIN_LINES, ONETIMECODES_MIN_REGIONS, ONETIMECODES_MIN_FUNCTIONS.
set -euo pipefail

min_lines="${ONETIMECODES_MIN_LINES:-100}"
min_regions="${ONETIMECODES_MIN_REGIONS:-100}"
min_functions="${ONETIMECODES_MIN_FUNCTIONS:-100}"

show_uncovered=0
run_tests=1
for argument in "$@"; do
    case "$argument" in
        --show-uncovered) show_uncovered=1 ;;
        --skip-tests) run_tests=0 ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$package_dir"

if [[ $run_tests -eq 1 ]]; then
    swift test --enable-code-coverage
fi

bin_path="$(swift build --show-bin-path)"
profile="$bin_path/codecov/default.profdata"
binary="$bin_path/OneTimeCodesPackageTests.xctest/Contents/MacOS/OneTimeCodesPackageTests"
[[ -f "$binary" ]] || binary="$bin_path/OneTimeCodesTests.xctest/Contents/MacOS/OneTimeCodesTests"
for path in "$profile" "$binary"; do
    [[ -f "$path" ]] || { echo "missing $path; run without --skip-tests" >&2; exit 1; }
done

sources=(Sources/OneTimeCodes/*.swift)
llvm_cov=(xcrun llvm-cov)

if [[ $show_uncovered -eq 1 ]]; then
    "${llvm_cov[@]}" show "$binary" -instr-profile="$profile" \
        -show-line-counts-or-regions -show-regions=false -use-color=false "${sources[@]}" |
        python3 -c '
import re, sys
file, start, last = None, None, None
def flush():
    global start
    if start is not None:
        print(f"  {start}-{last}" if start != last else f"  {start}")
        start = None
for line in sys.stdin:
    if line.startswith("/") and line.rstrip().endswith(":"):
        flush(); file = line.rstrip()[:-1]; print(file); continue
    match = re.match(r"\s*(\d+)\|\s*([^|]*)\|", line)
    if not match:
        continue
    number, count = int(match.group(1)), match.group(2).strip()
    if count == "0":
        if start is None: start = number
        last = number
    else:
        flush()
flush()
'
fi

summary="$(mktemp)"
trap 'rm -f "$summary"' EXIT
"${llvm_cov[@]}" export "$binary" -instr-profile="$profile" -summary-only "${sources[@]}" > "$summary"

python3 - "$summary" "$min_lines" "$min_regions" "$min_functions" <<'PY'
import json, os, sys

path, minimums = sys.argv[1], dict(zip(("lines", "regions", "functions"), map(float, sys.argv[2:5])))
data = json.load(open(path))["data"][0]
kinds = ("lines", "regions", "functions")

def percent(entry):
    return 100.0 * entry["covered"] / entry["count"] if entry["count"] else 100.0

def row(name, summary):
    cells = ["%6.2f%% (%d/%d)" % (percent(summary[k]), summary[k]["covered"], summary[k]["count"]) for k in kinds]
    return "%-30s %20s %20s %20s" % (name, *cells)

print("%-30s %20s %20s %20s" % ("File", "Lines", "Regions", "Functions"))
for item in sorted(data["files"], key=lambda f: f["filename"]):
    print(row(os.path.basename(item["filename"]), item["summary"]))
totals = data["totals"]
print(row("TOTAL", totals))
print("Thresholds: lines %g%%, regions %g%%, functions %g%%" % tuple(minimums[k] for k in kinds))

failed = [k for k in kinds if percent(totals[k]) < minimums[k]]
for kind in failed:
    print("FAIL: %s %.2f%% < %g%%" % (kind, percent(totals[kind]), minimums[kind]), file=sys.stderr)
sys.exit(1 if failed else 0)
PY
