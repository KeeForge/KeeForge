#!/usr/bin/env python3
"""Check presentation boundaries before generated projects reach local or CI builds."""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def violations(path: str, source: str) -> list[str]:
    failures = []
    for number, line in enumerate(source.splitlines(), 1):
        if path.startswith("KeeForge/ViewModels/") and re.match(
            r"\s*(?:@\w+\s+|public\s+|internal\s+)?import\s+SwiftUI\b", line
        ):
            failures.append(f"{path}:{number}: view models must not import SwiftUI")
        if path == "KeeForge/Views/Settings/SettingsView.swift" and re.search(
            r"\bSettingsService\.\w+\s*=(?!=)", line
        ):
            failures.append(f"{path}:{number}: persist preferences through AppSettingsViewModel")
    return failures


def self_test():
    checks = [
        ("KeeForge/ViewModels/FutureWorkflow.swift", "import SwiftUI", True),
        ("KeeForge/ViewModels/FutureWorkflow.swift", "@preconcurrency import SwiftUI", True),
        ("KeeForge/ViewModels/FutureWorkflow.swift", "import Foundation\nimport Observation", False),
        ("KeeForge/Views/Settings/SettingsView.swift", "SettingsService.clipboardTimeout = value", True),
        ("KeeForge/Views/Settings/SettingsView.swift", "SettingsService.clipboardTimeout == value", False),
        ("KeeForge/Views/Entry/EntryEditView.swift", "import SwiftUI", False),
    ]
    for path, source, expected in checks:
        assert bool(violations(path, source)) == expected, (path, source)


def main() -> int:
    if "--self-test" in sys.argv:
        self_test()
    paths = sorted((ROOT / "KeeForge/ViewModels").rglob("*.swift"))
    paths.append(ROOT / "KeeForge/Views/Settings/SettingsView.swift")
    failures = [
        failure
        for path in paths
        for failure in violations(str(path.relative_to(ROOT)), path.read_text())
    ]
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Presentation architecture checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
