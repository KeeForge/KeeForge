#!/usr/bin/env python3
"""Check that the Cloud schemes partition UI coverage and run all unit tests."""

import copy
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SCHEMES = ("KeeForgeCloudUnitTests", "KeeForgeCloudUIA", "KeeForgeCloudUIB")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(schemes, classes):
    targets = []
    for name, expected in zip(SCHEMES, ("KeeForgeTests", "KeeForgeUITests", "KeeForgeUITests")):
        action = schemes[name].find("TestAction")
        require(action is not None, f"{name}: missing TestAction")
        require(action.find("TestPlans") is None, f"{name}: test plans override scheme selection")
        refs = action.findall("Testables/TestableReference")
        require(len(refs) == 1, f"{name}: expected exactly one test target")
        target = refs[0]
        ref = target.find("BuildableReference")
        require(ref is not None and ref.get("BlueprintName") == expected,
                f"{name}: expected {expected}")
        require(target.get("skipped") == "NO", f"{name}: target is skipped")
        require(target.get("parallelizable") == "NO", f"{name}: tests must remain serial")
        targets.append(target)

    unit, group_a, group_b = targets
    require(unit.find("SelectedTests") is None and unit.find("SkippedTests") is None
            and unit.get("useTestSelectionWhitelist") != "YES", "Unit coverage must be unfiltered")
    require(group_a.get("useTestSelectionWhitelist") == "YES"
            and group_a.find("SkippedTests") is None, "UI A must select whole classes")
    require(group_b.get("useTestSelectionWhitelist") != "YES"
            and group_b.find("SelectedTests") is None, "UI B must run the complement of UI A")
    selected = [test.get("Identifier") for test in group_a.findall("SelectedTests/Test")]
    skipped = [test.get("Identifier") for test in group_b.findall("SkippedTests/Test")]
    require(selected and len(selected) == len(set(selected)), "UI A selection is empty or duplicated")
    require(len(skipped) == len(set(skipped)) and set(selected) == set(skipped),
            "UI A selection and UI B exclusions differ: coverage is missing or duplicated")
    require(set(selected) <= classes, f"Unknown UI classes: {set(selected) - classes}")
    require(classes - set(selected), "UI B has no test classes")
    return len(selected), len(classes - set(selected))


def test_classes():
    classes = set()
    for path in (ROOT / "KeeForgeUITests").glob("*.swift"):
        parts = re.split(r"^\s*(?:final\s+)?class\s+(\w+)\s*:", path.read_text(), flags=re.M)
        for index in range(1, len(parts), 2):
            if re.search(r"^\s*func test\w+\(", parts[index + 1], flags=re.M):
                classes.add(parts[index])
    require(classes, "No UI test classes found")
    return classes


def self_test(schemes, classes):
    a, b = validate(schemes, classes)
    require(validate(schemes, classes | {"FutureUITests"}) == (a, b + 1),
            "New UI classes must be covered automatically")
    for mutation in ("missing", "duplicate", "unit", "parallel", "skipped"):
        changed = copy.deepcopy(schemes)
        target = changed[SCHEMES[2]].find("TestAction/Testables/TestableReference")
        exclusions = target.find("SkippedTests")
        if mutation == "missing":
            ET.SubElement(exclusions, "Test", Identifier=next(iter(classes - {
                test.get("Identifier") for test in exclusions
            })))
        elif mutation == "duplicate":
            exclusions.remove(exclusions[0])
        elif mutation == "unit":
            unit = changed[SCHEMES[0]].find("TestAction/Testables/TestableReference")
            ET.SubElement(ET.SubElement(unit, "SkippedTests"), "Test", Identifier="SomeUnitTests")
        elif mutation == "parallel":
            target.set("parallelizable", "YES")
        else:
            target.set("skipped", "YES")
        try:
            validate(changed, classes)
        except ValueError:
            continue
        raise ValueError(f"Self-test accepted invalid {mutation} coverage")
    print("Cloud scheme negative fixtures passed")


if __name__ == "__main__":
    try:
        directory = ROOT / "KeeForge.xcodeproj/xcshareddata/xcschemes"
        schemes = {name: ET.parse(directory / f"{name}.xcscheme").getroot() for name in SCHEMES}
        classes = test_classes()
        a, b = validate(schemes, classes)
        if "--self-test" in sys.argv[1:]:
            self_test(schemes, classes)
        print(f"Cloud coverage: all unit tests; {a} UI classes in A + {b} in B, no gaps or duplicates")
    except (ValueError, OSError, ET.ParseError) as error:
        sys.exit(f"Cloud scheme validation failed: {error}")
