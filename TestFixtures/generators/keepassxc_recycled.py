"""`compatibility/keepassxc-recycled.kdbx` -- an entry and a group that
KeePassXC itself moved to its Recycle Bin.

KeePassXC records each recycled item's original group in the KDBX 4.1
`<PreviousParentGroup>` element and raises the file to 4.1 for it. Every other
fixture's restore reference was written by KeeForge or inserted with lxml, so
every change here comes from `keepassxc-cli` (`rm` and `rmdir` recycle the way
the app's Delete does) to prove KeeForge restores KeePassXC's own references;
pykeepass only creates the empty file. Building it therefore needs
keepassxc-cli, found through `KEEPASSXC_CLI`, `PATH`, or the default macOS app
location.

Content: `Work` holds nothing after the build. `Recycle Bin` holds the entry
`Recycled Login` (`recycled-user`) and the group `Recycled Projects` with
`Nested Login` (`nested-user`); both were recycled out of `Work`.
"""

import base64
import os
import shutil
from pathlib import Path

from ._common import Generator, fixture_path, new_database, pykeepass, run_keepassxc_cli

PASSWORD = "keepassxc-recycled"
ORIGINAL_GROUP = "Work"
RECYCLED_ENTRY = "Recycled Login"
RECYCLED_GROUP = "Recycled Projects"
NESTED_ENTRY = "Nested Login"
DEFAULT_KEEPASSXC_CLI = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"


def keepassxc_cli_path() -> str:
    path = os.environ.get("KEEPASSXC_CLI") or shutil.which("keepassxc-cli") or DEFAULT_KEEPASSXC_CLI
    if not Path(path).exists():
        raise AssertionError("keepassxc-recycled needs keepassxc-cli; set KEEPASSXC_CLI")
    return path


def run(cli: str, *args: str) -> None:
    result = run_keepassxc_cli(cli, args, PASSWORD)
    if result.returncode != 0:
        raise AssertionError(f"keepassxc-cli {' '.join(args)} failed:\n{result.stderr}")


def build(path: Path) -> None:
    cli = keepassxc_cli_path()
    # pykeepass only creates the empty file: its light Argon2 parameters keep
    # the fixture cheap to open, where `db-create` tunes the KDF to at least
    # 100 ms on this machine. KeePassXC rewrites the whole file on every
    # command below.
    new_database(path, PASSWORD).save()
    db = str(path)
    run(cli, "mkdir", "-q", db, ORIGINAL_GROUP)
    run(cli, "mkdir", "-q", db, f"{ORIGINAL_GROUP}/{RECYCLED_GROUP}")
    run(cli, "add", "-q", "-u", "recycled-user", db, f"{ORIGINAL_GROUP}/{RECYCLED_ENTRY}")
    run(cli, "add", "-q", "-u", "nested-user", db, f"{ORIGINAL_GROUP}/{RECYCLED_GROUP}/{NESTED_ENTRY}")
    run(cli, "rm", "-q", db, f"{ORIGINAL_GROUP}/{RECYCLED_ENTRY}")
    run(cli, "rmdir", "-q", db, f"{ORIGINAL_GROUP}/{RECYCLED_GROUP}")


def verify(path: Path, keepassxc_cli: str | None) -> None:
    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    if kp.version != (4, 1):
        raise AssertionError(f"{path.name}: expected KDBX 4.1, got {kp.version}")
    original = kp.find_groups(name=ORIGINAL_GROUP, first=True)
    recycle_bin = kp.recyclebin_group
    if original is None or recycle_bin is None:
        raise AssertionError(f"{path.name}: '{ORIGINAL_GROUP}' or the Recycle Bin is missing")
    original_b64 = base64.b64encode(original.uuid.bytes).decode()

    entry = kp.find_entries(title=RECYCLED_ENTRY, first=True)
    group = kp.find_groups(name=RECYCLED_GROUP, first=True)
    for label, item in ((RECYCLED_ENTRY, entry), (RECYCLED_GROUP, group)):
        if item is None or item.parentgroup.uuid != recycle_bin.uuid:
            raise AssertionError(f"{path.name}: '{label}' is not in the Recycle Bin")
        if item._element.findtext("PreviousParentGroup") != original_b64:
            raise AssertionError(f"{path.name}: '{label}' does not name '{ORIGINAL_GROUP}' as its previous parent")
    if kp.find_entries(title=NESTED_ENTRY, group=group, first=True) is None:
        raise AssertionError(f"{path.name}: '{NESTED_ENTRY}' is not inside '{RECYCLED_GROUP}'")
    print(f"{path.name}: KDBX 4.1; '{RECYCLED_ENTRY}' and '{RECYCLED_GROUP}' recycled from '{ORIGINAL_GROUP}'")


GENERATORS = [
    Generator(
        name="keepassxc-recycled",
        output_path=fixture_path("compatibility", "keepassxc-recycled.kdbx"),
        build=build,
        verify=verify,
    )
]
