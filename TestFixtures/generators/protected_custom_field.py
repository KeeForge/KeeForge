"""`protected-custom-field.kdbx` -- an entry whose protected custom field also
survives into history, so the UI tests can assert the field stays masked on both
the current version and the history version.
"""

from pathlib import Path

from ._common import Generator, fixture_path, new_database, pykeepass

PASSWORD = "testpassword123"
ENTRY_TITLE = "Protected Custom"
FIELD_KEY = "API Token"
FIELD_VALUE = "custom-secret"


def build(path: Path) -> None:
    database = new_database(path, PASSWORD)
    group = database.add_group(database.root_group, "Secrets")
    entry = database.add_entry(group, ENTRY_TITLE, "fixture-user", "fixture-password")
    entry.set_custom_property(FIELD_KEY, FIELD_VALUE, protect=True)
    entry.save_history()
    entry.notes = "Current version"
    database.save()


def assert_protected(path: Path, entry, label: str) -> None:
    field = next(
        (
            string
            for string in entry._element.findall("String")
            if string.find("Key").text == FIELD_KEY
        ),
        None,
    )
    if field is None:
        raise AssertionError(f"{path.name}: {label} is missing the {FIELD_KEY!r} custom field")
    if field.find("Value").text != FIELD_VALUE:
        raise AssertionError(f"{path.name}: {label} custom field value drifted")
    if field.find("Value").get("Protected") != "True":
        raise AssertionError(f"{path.name}: {label} custom field is not protected")


def verify(path: Path, keepassxc_cli: str | None) -> None:
    database = pykeepass.PyKeePass(str(path), password=PASSWORD)
    entry = database.find_entries(title=ENTRY_TITLE, first=True)
    if entry is None:
        raise AssertionError(f"{path.name}: entry {ENTRY_TITLE!r} missing")
    assert_protected(path, entry, "current entry")
    if len(entry.history) != 1:
        raise AssertionError(
            f"{path.name}: expected 1 history version, found {len(entry.history)}"
        )
    assert_protected(path, entry.history[0], "history entry")
    print(f"{path.name}: protected custom field present in current entry and history")


GENERATORS = [
    Generator(
        name="protected-custom-field",
        output_path=fixture_path("protected-custom-field.kdbx"),
        build=build,
        verify=verify,
    )
]
