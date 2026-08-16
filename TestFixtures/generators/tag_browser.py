"""`tag-browser.kdbx` -- the tagged fixture the tag-browser UI test needs.

Neither `test.kdbx` nor `demo.kdbx` carries a single entry tag, so the tag
browser had no fixture-backed content to assert against. This authors a small
KDBX4 / AES-256 database (same recipe as `autofill-union.kdbx` and
`compatibility/attachments.kdbx` -- `keepassxc-cli db-create` only writes KDBX
3.1) whose tags cover the cases the browser has to get right:

* `shared` is carried by two entries in two different groups, so a count above
  one is asserted against real data;
* `Work` and `work` are a case-variant pair, which the exact-string tag identity
  keeps apart and the Finder-style display sort keeps adjacent;
* `archive` sits on a single entry, so the "1 entry" plural branch has a
  carrier;
* `Personal Notes` contains a space, exercising the hyphenated accessibility
  identifier suffix (`tag-list.row.personal-notes`).
"""

from pathlib import Path

from ._common import Generator, fixture_path, new_database, pykeepass

PASSWORD = "testpassword123"

# group name -> entries. Documented in TestFixtures/README.md; the UI test
# depends on "Tagged" / "Router Admin" / the `shared` tag and its count.
GROUPS = {
    "Tagged": [
        {
            "title": "Router Admin",
            "username": "tag-router-user",
            "password": "TagRouterSecret1",
            "url": "https://router-tagged.example.com",
            "tags": ["shared", "Work", "Personal Notes"],
        },
        {
            "title": "Mail Account",
            "username": "tag-mail-user",
            "password": "TagMailSecret2",
            "url": "https://mail-tagged.example.com",
            "tags": ["shared", "work"],
        },
        {
            "title": "Untagged Entry",
            "username": "tag-plain-user",
            "password": "TagPlainSecret3",
            "url": "https://plain-tagged.example.com",
            "tags": [],
        },
    ],
    "Archive": [
        {
            "title": "Old Backup",
            "username": "tag-archive-user",
            "password": "TagArchiveSecret4",
            "url": "https://archive-tagged.example.com",
            "tags": ["archive"],
        },
    ],
}

# tag -> number of entries expected to carry it, checked by verify().
EXPECTED_TAG_COUNTS = {
    "shared": 2,
    "Work": 1,
    "work": 1,
    "Personal Notes": 1,
    "archive": 1,
}


def build(path: Path) -> None:
    kp = new_database(path, PASSWORD)

    for group_name, entry_specs in GROUPS.items():
        group = kp.add_group(kp.root_group, group_name)
        for spec in entry_specs:
            entry = kp.add_entry(
                group,
                spec["title"],
                spec["username"],
                spec["password"],
                url=spec["url"],
            )
            if spec["tags"]:
                entry.tags = spec["tags"]

    kp.save()


def verify(path: Path, keepassxc_cli: str | None) -> None:
    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    if kp.version[0] != 4:
        raise AssertionError(f"{path.name}: expected KDBX 4.x, got {kp.version}")

    seen: dict[str, int] = {}
    for group_name, entry_specs in GROUPS.items():
        group = kp.find_groups(name=group_name, first=True)
        if group is None:
            raise AssertionError(f"{path.name}: group {group_name!r} missing")
        for spec in entry_specs:
            entry = kp.find_entries(title=spec["title"], first=True)
            if entry is None:
                raise AssertionError(f"{path.name}: entry {spec['title']!r} missing")
            tags = entry.tags or []
            if tags != spec["tags"] and not (tags == [] and spec["tags"] == []):
                raise AssertionError(
                    f"{path.name}: {spec['title']} tags {tags!r}, expected {spec['tags']!r}"
                )
            for tag in tags:
                seen[tag] = seen.get(tag, 0) + 1

    if seen != EXPECTED_TAG_COUNTS:
        raise AssertionError(f"{path.name}: tag counts {seen!r}, expected {EXPECTED_TAG_COUNTS!r}")

    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, "
        f"cipher={kp.encryption_algorithm}, kdf={kp.kdf_algorithm}, tags={seen}"
    )


GENERATORS = [
    Generator(
        name="tag-browser",
        output_path=fixture_path("tag-browser.kdbx"),
        build=build,
        verify=verify,
    )
]
