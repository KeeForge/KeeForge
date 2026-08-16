"""`compatibility/group-tags.kdbx` -- the KDBX 4.1 fixture with group `<Tags>`.

Group tags exist only in KDBX >= 4.1, and KeeForge parses them READ-ONLY (it
never authors or edits one), so the fixture must come from an independent
implementation: pykeepass authors the file, KDBXParserTests and the
compatibility gate prove KeeForge reads and preserves it. The groups cover every
`<Tags>` state the parser models:

* `Projects` -- `<Tags>team;shared</Tags>` plus a group `<Notes>`, so a real file
  exercises two structured siblings and the unknown-sibling positioning around
  them (the notes text itself predates KeeForge structuring `<Notes>` and is
  kept verbatim so the fixture bytes stay put);
* `Projects/Client Work` -- nested tagged group (`billable`) whose entry also
  carries its own entry tag, for inheritance accumulation;
* `Empty Tags Group` -- an EMPTY `<Tags/>` element (present but contentless, the
  state `hasTagsElement` exists to preserve);
* `Plain Group` -- no `<Tags>` element at all (KeeForge must never add one);
* `Recycle Bin` -- created by trashing `Trashed Login`, so the fixture also
  carries Meta/RecycleBinUUID alongside the group tags.

pykeepass writes the group tag text `;`-separated (KeePass's canonical form), so
the fixture also exercises the parser's semicolon split.

pykeepass writes KDBX 4.0 with no public setter for the format version, so the
minor version is bumped by mutating the low-level Construct header container
directly; the cache drop that makes the mutation reach the file is explained in
`_common.drop_rawcopy_cache`. pykeepass also has no group-tag API (`tags` exists
on entries only), so the group `<Tags>` elements are inserted with lxml directly
on each group's backing element, at KeePass's canonical position.
"""

import hashlib
from pathlib import Path

from lxml import etree

from ._common import (
    AESKDF_UUID,
    ARGON2D_UUID,
    ARGON2ID_UUID,
    Generator,
    drop_rawcopy_cache,
    fixture_path,
    kdf_parameters,
    new_database,
    parse_outer_header,
    pykeepass,
    verify_keepassxc_lists_group,
)

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

KDF_NAMES = {
    ARGON2D_UUID: "argon2d",
    ARGON2ID_UUID: "argon2id",
    AESKDF_UUID: "aeskdf",
}


def set_group_tags(group, text: str) -> None:
    """Insert a `<Tags>` element on the group at KeePass's canonical position
    (after the scalar children, before any `<Entry>`/`<Group>` children)."""
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


def build(path: Path) -> None:
    kp = new_database(path, PASSWORD)

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

    # Trashing creates the Recycle Bin group and sets Meta/RecycleBinUUID, so the
    # fixture carries a real bin alongside the group tags. The bin itself
    # deliberately gets no tags -- recycle-bin tag exclusion is covered by
    # in-memory unit tests (DatabaseViewModelTests), not this fixture.
    trashed = kp.add_entry(kp.root_group, "Trashed Login", "trashed-user", "GroupTagTrashed5")
    kp.trash_entry(trashed)

    set_group_tags(projects, "team;shared")
    set_group_tags(client_work, "billable")
    set_group_tags(empty_tags_group, "")  # empty element: <Tags/>
    # Plain Group: no element at all.

    # KDBX 4.1 is the version that introduced group tags.
    kp.kdbx.header.value.minor_version = 1
    drop_rawcopy_cache(kp)
    kp.save()


def verify(path: Path, keepassxc_cli: str | None) -> None:
    raw = path.read_bytes()
    header = parse_outer_header(raw)
    if (header.major, header.minor) != (4, 1):
        raise AssertionError(
            f"{path.name}: expected raw header version 4.1, got {header.major}.{header.minor}"
        )

    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    if kp.version != (4, 1):
        raise AssertionError(f"{path.name}: pykeepass reports version {kp.version}, expected (4, 1)")

    # NOTE: kp.kdf_algorithm is unusable here -- pykeepass 4.1.1 only maps the
    # KDF name for versions (3, 1) and exactly (4, 0), returning None for 4.1.
    kdf_uuid = kdf_parameters(header)["$UUID"]
    kdf_name = KDF_NAMES.get(kdf_uuid)
    if kdf_name is None:
        raise AssertionError(f"{path.name}: unrecognized KDF UUID {kdf_uuid.hex()}")

    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, kdf={kdf_name}, "
        f"sha256={hashlib.sha256(raw).hexdigest()}"
    )

    for group_name, expected_text in EXPECTED_GROUP_TAGS.items():
        group = kp.find_groups(name=group_name, first=True)
        if group is None:
            raise AssertionError(f"{path.name}: group {group_name!r} missing after reload")
        tags_element = group._element.find("Tags")
        actual = None if tags_element is None else (tags_element.text or "")
        if actual != expected_text:
            raise AssertionError(
                f"{path.name}: group {group_name!r} Tags mismatch "
                f"(expected {expected_text!r}, got {actual!r})"
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

    if keepassxc_cli:
        verify_keepassxc_lists_group(path, keepassxc_cli, PASSWORD, "Projects")


GENERATORS = [
    Generator(
        name="group-tags",
        output_path=fixture_path("compatibility", "group-tags.kdbx"),
        build=build,
        verify=verify,
    )
]
