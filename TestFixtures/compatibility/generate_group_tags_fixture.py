#!/usr/bin/env python3
"""Generate `group-tags.kdbx`, the KDBX 4.1 fixture with group `<Tags>`.

Group tags exist only in KDBX >= 4.1, and KeeForge parses them READ-ONLY (it
never authors or edits one), so the fixture must come from an independent
implementation: pykeepass authors the file, KDBXParserTests and the
compatibility gate prove KeeForge reads and preserves it. The groups cover
every `<Tags>` state the parser models:

* `Projects` -- `<Tags>team;shared</Tags>` plus a group `<Notes>`, so a real
  file exercises two structured siblings and the unknown-sibling positioning
  around them (the notes text itself predates KeeForge structuring `<Notes>`
  and is kept verbatim so the fixture bytes stay put);
* `Projects/Client Work` -- nested tagged group (`billable`) whose entry also
  carries its own entry tag, for inheritance accumulation;
* `Empty Tags Group` -- an EMPTY `<Tags/>` element (present but contentless,
  the state `hasTagsElement` exists to preserve);
* `Plain Group` -- no `<Tags>` element at all (KeeForge must never add one);
* `Recycle Bin` -- created by trashing `Trashed Login`, so the fixture also
  carries Meta/RecycleBinUUID alongside the group tags.

pykeepass writes the group tag text `;`-separated (KeePass's canonical form),
so the fixture also exercises the parser's semicolon split.

Requires: pykeepass (`pip3 install --user pykeepass`). Verified against
pykeepass 4.1.1.post1 -- re-check the two API assumptions below if a newer
pykeepass changes its internals:

1. pykeepass writes KDBX 4.0 by default and has no public setter for the
   format version. The minor version is changed by mutating the low-level
   Construct header container directly: `kp.kdbx.header.value.minor_version`.
2. That header is wrapped in Construct's `RawCopy`, which caches the
   originally-parsed (4.0) header bytes under a `data` key and re-emits them
   verbatim on build, IGNORING any mutations to `value` -- so after changing
   `minor_version`, `del kp.kdbx.header["data"]` is required or the saved
   file silently stays 4.0. Same mechanism documented in
   `generate_foreign_cipher_fixtures.py` for the cipher UUID; see
   `construct.RawCopy._build`.

pykeepass also has no group-tag API (`tags` exists on entries only), so the
group `<Tags>` elements are inserted with lxml directly on each group's
backing element, at KeePass's canonical position (before the child `<Entry>`/
`<Group>` elements).

Output is deterministic in CONTENT (groups, entries, tags, passwords) but NOT
in bytes: pykeepass generates a fresh master seed, encryption IV, and KDF
salt on every `save()`. Tests assert decoded content, not raw bytes.

Usage (from the repo root):

    python3 TestFixtures/compatibility/generate_group_tags_fixture.py          # regenerate
    python3 TestFixtures/compatibility/generate_group_tags_fixture.py --check  # verify only
"""

import argparse
import hashlib
import struct
import sys
from pathlib import Path

try:
    import pykeepass
except ImportError:
    raise SystemExit(
        "pykeepass is required: pip3 install --user pykeepass "
        "(or install it into a venv and re-run with that interpreter)"
    )

from lxml import etree

OUTPUT_PATH = Path(__file__).resolve().parent / "group-tags.kdbx"
PASSWORD = "testpassword123"

PROJECTS_NOTES = "Group notes ride along as unknown XML next to the structured Tags element."

# Expected group -> Tags element text after reload. None = no <Tags> element;
# "" = element present but empty. Mirrored by KDBXParserTests and
# KDBXCompatibilitySupport -- change all three together.
EXPECTED_GROUP_TAGS = {
    "Projects": "team;shared",
    "Client Work": "billable",
    "Empty Tags Group": "",
    "Plain Group": None,
}

# title -> (username, password, entry tags) -- also documented in
# TestFixtures/README.md and pinned by KDBXCompatibilitySupport's expectation
# tables (`Alpha Login` / `GroupTagAlpha1` feeds the keepassxc-cli probe).
EXPECTED_ENTRIES = {
    "Alpha Login": ("alpha-user", "GroupTagAlpha1", None),
    "Beta Login": ("beta-user", "GroupTagBeta2", ["own-tag"]),
    "Gamma Login": ("gamma-user", "GroupTagGamma3", None),
    "Delta Login": ("delta-user", "GroupTagDelta4", None),
    "Trashed Login": ("trashed-user", "GroupTagTrashed5", None),
}


def set_group_tags(group, text):
    """Insert a `<Tags>` element on the group at KeePass's canonical position
    (after the scalar children, before any `<Entry>`/`<Group>` children).
    pykeepass has no group-tag API, hence lxml on the backing element."""
    tags = etree.Element("Tags")
    if text:
        tags.text = text
    element = group._element
    insert_at = len(element)
    for index, child in enumerate(element):
        if child.tag in ("Entry", "Group"):
            insert_at = index
            break
    element.insert(insert_at, tags)


def build_fixture(path: Path) -> None:
    kp = pykeepass.create_database(str(path), password=PASSWORD)

    projects = kp.add_group(kp.root_group, "Projects", notes=PROJECTS_NOTES)
    kp.add_entry(
        projects,
        "Alpha Login",
        "alpha-user",
        "GroupTagAlpha1",
        url="https://alpha.example.com",
    )
    client_work = kp.add_group(projects, "Client Work")
    kp.add_entry(
        client_work,
        "Beta Login",
        "beta-user",
        "GroupTagBeta2",
        url="https://beta.example.com",
        tags=["own-tag"],
    )

    empty_tags_group = kp.add_group(kp.root_group, "Empty Tags Group")
    kp.add_entry(empty_tags_group, "Gamma Login", "gamma-user", "GroupTagGamma3")

    plain_group = kp.add_group(kp.root_group, "Plain Group")
    kp.add_entry(plain_group, "Delta Login", "delta-user", "GroupTagDelta4")

    # Trashing creates the Recycle Bin group and sets Meta/RecycleBinUUID, so
    # the fixture carries a real bin alongside the group tags. The bin itself
    # deliberately gets no tags -- recycle-bin tag exclusion is covered by
    # in-memory unit tests (DatabaseViewModelTests), not this fixture.
    trashed = kp.add_entry(kp.root_group, "Trashed Login", "trashed-user", "GroupTagTrashed5")
    kp.trash_entry(trashed)

    set_group_tags(projects, "team;shared")
    set_group_tags(client_work, "billable")
    set_group_tags(empty_tags_group, "")  # empty element: <Tags/>
    # Plain Group: no element at all.

    # See module docstring: bump the declared format version to KDBX 4.1 (the
    # version that introduced group tags) and drop RawCopy's cached 4.0
    # header bytes so the mutation actually reaches the file.
    kp.kdbx.header.value.minor_version = 1
    del kp.kdbx.header["data"]
    kp.save()


def verify(path: Path) -> None:
    # Independent header read: don't just trust the library that wrote it.
    raw = path.read_bytes()
    minor, major = struct.unpack("<HH", raw[8:12])
    if (major, minor) != (4, 1):
        raise AssertionError(f"{path.name}: expected raw header version 4.1, got {major}.{minor}")

    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    if kp.version != (4, 1):
        raise AssertionError(f"{path.name}: pykeepass reports version {kp.version}, expected (4, 1)")

    # NOTE: kp.kdf_algorithm is unusable here -- pykeepass 4.1.1 only maps the
    # KDF name for versions (3, 1) and exactly (4, 0), returning None for 4.1.
    # Read the KDF UUID from the parsed variant dictionary instead.
    kdf_uuid = kp.kdbx.header.value.dynamic_header.kdf_parameters.data.dict["$UUID"].value
    kdf_names = {
        bytes.fromhex("ef636ddf8c29444b91f7a9a403e30a0c"): "argon2d",
        bytes.fromhex("9e298b1956db4773b23dfc3ec6f0a1e6"): "argon2id",
        bytes.fromhex("c9d9f39a628a4460bf740d08c18a4fea"): "aeskdf",
    }
    kdf_name = kdf_names.get(kdf_uuid)
    if kdf_name is None:
        raise AssertionError(f"{path.name}: unrecognized KDF UUID {kdf_uuid.hex()}")

    sha256 = hashlib.sha256(raw).hexdigest()
    print(f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, kdf={kdf_name}, sha256={sha256}")

    for group_name, expected_text in EXPECTED_GROUP_TAGS.items():
        group = kp.find_groups(name=group_name, first=True)
        if group is None:
            raise AssertionError(f"{path.name}: group {group_name!r} missing after reload")
        tags_element = group._element.find("Tags")
        actual = None if tags_element is None else (tags_element.text or "")
        if actual != expected_text:
            raise AssertionError(
                f"{path.name}: group {group_name!r} Tags mismatch (expected {expected_text!r}, got {actual!r})"
            )
        print(f"  group {group_name!r}: Tags={actual!r}")

    recyclebin = kp.recyclebin_group
    if recyclebin is None:
        raise AssertionError(f"{path.name}: recycle bin group missing")
    print(f"  recycle bin: {recyclebin.name!r} with {len(recyclebin.entries)} entry(ies)")

    for title, (username, password, tags) in EXPECTED_ENTRIES.items():
        entry = kp.find_entries(title=title, first=True)
        if entry is None:
            raise AssertionError(f"{path.name}: entry {title!r} missing after reload")
        if entry.username != username or entry.password != password:
            raise AssertionError(f"{path.name}: entry {title!r} credential mismatch after reload")
        if (entry.tags or None) != tags:
            raise AssertionError(
                f"{path.name}: entry {title!r} tags mismatch (expected {tags!r}, got {entry.tags!r})"
            )
        print(f"  entry {title!r}: username={username!r}, tags={tags!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the existing fixture on disk instead of regenerating it",
    )
    args = parser.parse_args()

    print(f"pykeepass version: {getattr(pykeepass, '__version__', 'unknown')}", file=sys.stderr)

    if not args.check:
        build_fixture(OUTPUT_PATH)
    verify(OUTPUT_PATH)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
