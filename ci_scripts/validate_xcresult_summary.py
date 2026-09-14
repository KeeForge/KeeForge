#!/usr/bin/env python3
"""Fail closed on the canonical XCTest result bundle summary."""

import argparse
import json
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise ValueError(message)


def nonnegative_int(summary: dict[str, object], name: str) -> int:
    value = summary.get(name)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"canonical summary has invalid {name}: {value!r}")
    return value


def read_summary(args: argparse.Namespace) -> dict[str, object]:
    if args.summary_file:
        try:
            raw = Path(args.summary_file).read_text(encoding="utf-8")
        except OSError as error:
            fail(f"cannot read canonical summary fixture: {error}")
    else:
        bundle = Path(args.result_bundle)
        if not bundle.is_dir():
            fail(f"missing XCTest result bundle: {bundle}")
        result = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"],
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            fail(f"xcresulttool could not read {bundle}: {detail}")
        raw = result.stdout
    try:
        summary = json.loads(raw)
    except json.JSONDecodeError as error:
        fail(f"malformed canonical XCTest summary: {error}")
    if not isinstance(summary, dict):
        fail("canonical XCTest summary is not an object")
    return summary


def validate(summary: dict[str, object], suite: str, xcodebuild_exit: int) -> None:
    result = summary.get("result")
    if not isinstance(result, str):
        fail(f"canonical summary has invalid result: {result!r}")
    total = nonnegative_int(summary, "totalTestCount")
    passed = nonnegative_int(summary, "passedTests")
    failed = nonnegative_int(summary, "failedTests")
    skipped = nonnegative_int(summary, "skippedTests")
    if total == 0:
        fail(f"{suite}: canonical result has no tests")
    if passed + failed == 0:
        fail(f"{suite}: canonical result has no executed tests (total={total}, skipped={skipped})")
    if failed != 0:
        fail(f"{suite}: canonical result reports {failed} failed test(s) with result={result!r}")
    if result != "Passed":
        fail(f"{suite}: canonical result is {result!r}, expected 'Passed'")
    if xcodebuild_exit not in (0, 65):
        fail(f"{suite}: xcodebuild exited {xcodebuild_exit} despite a passing canonical result")
    print(
        f"{suite}: PASS (canonical xcresult: total={total}, passed={passed}, "
        f"failed={failed}, skipped={skipped}, result={result})"
    )
    if xcodebuild_exit == 65:
        print(
            f"::warning::{suite}: xcodebuild exited 65 after a passing canonical result; "
            "retaining the full log and result bundle as teardown evidence."
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--result-bundle")
    source.add_argument("--summary-file")
    parser.add_argument("--suite", required=True)
    parser.add_argument("--xcodebuild-exit", required=True, type=int)
    args = parser.parse_args()
    if args.xcodebuild_exit < 0:
        parser.error("--xcodebuild-exit must be nonnegative")
    try:
        validate(read_summary(args), args.suite, args.xcodebuild_exit)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
