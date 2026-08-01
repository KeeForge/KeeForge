#!/usr/bin/env python3
"""Generate the protected-custom-field UI-test fixture.

Requires pykeepass (`pip3 install --user pykeepass`). Run from the repo root:

    python3 TestFixtures/generate_protected_custom_field_fixture.py
    python3 TestFixtures/generate_protected_custom_field_fixture.py --check
"""

import argparse
from pathlib import Path

import pykeepass

OUTPUT_PATH = Path(__file__).resolve().parent / "protected-custom-field.kdbx"
PASSWORD = "testpassword123"
FIELD_KEY = "API Token"
FIELD_VALUE = "custom-secret"


def build_fixture(path: Path) -> None:
    if path.exists():
        path.unlink()

    database = pykeepass.create_database(str(path), password=PASSWORD)
    group = database.add_group(database.root_group, "Secrets")
    entry = database.add_entry(group, "Protected Custom", "fixture-user", "fixture-password")
    entry.set_custom_property(FIELD_KEY, FIELD_VALUE, protect=True)
    entry.save_history()
    entry.notes = "Current version"
    database.save()


def assert_protected(entry: object) -> None:
    field = next(
        string
        for string in entry._element.findall("String")
        if string.find("Key").text == FIELD_KEY
    )
    assert field.find("Value").text == FIELD_VALUE
    assert field.find("Value").get("Protected") == "True"


def verify(path: Path) -> None:
    database = pykeepass.PyKeePass(str(path), password=PASSWORD)
    entry = database.find_entries(title="Protected Custom", first=True)
    assert entry is not None
    assert_protected(entry)
    assert len(entry.history) == 1
    assert_protected(entry.history[0])
    print(f"{path.name}: protected custom field present in current entry and history")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not args.check:
        build_fixture(OUTPUT_PATH)
    verify(OUTPUT_PATH)


if __name__ == "__main__":
    main()
