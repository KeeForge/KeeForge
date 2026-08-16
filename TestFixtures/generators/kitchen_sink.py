"""`kitchen-sink.kdbx` -- one rich fixture replacing five narrow ones.

`tag-browser`, `protected-custom-field`, `icon-picker`,
`compatibility/group-tags` and `compatibility/attachments` each existed for a
single feature, so a test needing two of them had no fixture at all and every
new aspect meant another file to bundle and maintain. This is the exact union
of all five, plus a TOTP entry, in one KDBX **4.1** / AES-256-CBC / Argon2d
database -- 4.1 because group `<Tags>` only exist from that minor version on.

Every section below carries the coverage its retired fixture used to own, and
the section comments say what each one is for. pykeepass authors the file -- an
implementation independent of KeeForge -- so the parser tests and the
compatibility gate prove KeeForge reads a foreign file rather than only its own.

Root groups, in child order: `Tagged`, `Archive`, `Secrets`, `Icons`,
`Projects` (with `Client Work`), `Empty Tags Group`, `Plain Group`,
`Attachments`, `Recycle Bin`. Nothing lives directly under the root.

Output is deterministic in CONTENT but NOT in bytes: pykeepass generates a
fresh master seed, encryption IV and KDF salt on every `save()`. Tests assert
decoded content, never raw bytes.
"""

import base64
import hashlib
import struct
import tempfile
import uuid
import zlib
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
    run_keepassxc_cli,
    verify_keepassxc_lists_group,
)

PASSWORD = "testpassword123"

KDF_NAMES = {
    ARGON2D_UUID: "argon2d",
    ARGON2ID_UUID: "argon2id",
    AESKDF_UUID: "aeskdf",
}


# --------------------------------------------------------------------------
# Tagged / Archive -- entry tags for the tag browser (was tag-browser.kdbx)
#
# Neither `test.kdbx` nor `demo.kdbx` carries a single entry tag, so the tag
# browser had no fixture-backed content to assert against. These tags cover the
# cases the browser has to get right:
#
# * `shared` is carried by two entries in two different groups, so a count above
#   one is asserted against real data (the app-level count is higher still --
#   see the note in `verify` about inherited group tags);
# * `Work` and `work` are a case-variant pair, which the exact-string tag
#   identity keeps apart and the Finder-style display sort keeps adjacent;
# * `archive` sits on a single entry, so the "1 entry" plural branch has a
#   carrier;
# * `Personal Notes` contains a space, exercising the hyphenated accessibility
#   identifier suffix (`tag-list.row.personal-notes`).
# --------------------------------------------------------------------------

# group name -> entries. Documented in TestFixtures/README.md; the UI test
# depends on "Tagged" / "Router Admin" / the `shared` tag and its count.
TAGGED_GROUPS = {
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

# tag -> number of entries carrying it as an OWN entry tag, checked by verify().
EXPECTED_ENTRY_TAG_COUNTS = {
    "shared": 2,
    "Work": 1,
    "work": 1,
    "Personal Notes": 1,
    "archive": 1,
    "own-tag": 1,
}


def add_tagged_groups(kp) -> None:
    for group_name, entry_specs in TAGGED_GROUPS.items():
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


# --------------------------------------------------------------------------
# Secrets -- protected custom fields (was protected-custom-field.kdbx) plus a
# TOTP entry.
#
# `Protected Custom` carries a protected custom field that also survives into
# history, so the UI tests can assert the field stays masked on both the current
# version and the history version.
# --------------------------------------------------------------------------

PROTECTED_TITLE = "Protected Custom"
PROTECTED_FIELD_KEY = "API Token"
PROTECTED_FIELD_VALUE = "custom-secret"
PROTECTED_NOTES = "Current version"

TOTP_TITLE = "TOTP Login"
TOTP_USERNAME = "totp-user"
TOTP_PASSWORD = "TotpSecret1"
TOTP_FIELD_KEY = "otp"
TOTP_FIELD_VALUE = (
    "otpauth://totp/KeeForge:totp-user"
    "?secret=JBSWY3DPEHPK3PXP&issuer=KeeForge&period=30&digits=6"
)


def add_secrets_group(kp) -> None:
    group = kp.add_group(kp.root_group, "Secrets")
    entry = kp.add_entry(group, PROTECTED_TITLE, "fixture-user", "fixture-password")
    entry.set_custom_property(PROTECTED_FIELD_KEY, PROTECTED_FIELD_VALUE, protect=True)
    entry.save_history()
    entry.notes = PROTECTED_NOTES

    # `otp` is pykeepass's reserved TOTP key, so it takes the dedicated argument
    # rather than set_custom_property; it lands as a protected `<String>`
    # exactly like KeePassXC writes it.
    kp.add_entry(group, TOTP_TITLE, TOTP_USERNAME, TOTP_PASSWORD, otp=TOTP_FIELD_VALUE)


# --------------------------------------------------------------------------
# Icons -- a Meta/CustomIcons image (was icon-picker.kdbx)
#
# No other bundled fixture carries a `Meta/CustomIcons` image, so the entry icon
# picker's custom-icon grid had no fixture-backed content to assert against.
#
# * `Icons/Custom Badge` displays the custom icon (`<CustomIconUUID>` set) and
#   carries a public URL, so "Download Website Icon" is offered enabled;
# * `Icons/Plain Entry` uses a standard icon and has no URL, so the download
#   action renders disabled, and ships no history.
#
# pykeepass exposes no custom-icon API, so the icon and the entry's
# `<CustomIconUUID>` are written straight into the XML tree; both are plain
# base64 text elements the format defines.
# --------------------------------------------------------------------------

# Hardcoded in KeeForgeUITests (accessibility identifier
# `entry-icon-picker.custom.<uppercase uuidString>`); change both together.
CUSTOM_ICON_UUID = uuid.UUID("4D9C2B1E-7A35-4E68-9B0D-52F16C8A3E77")

ICON_CUSTOM_URL = "https://icons-fixture.example.com"


def make_png() -> bytes:
    """A deterministic 8x8 solid-color RGB PNG, small but decodable by UIImage."""

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    width = height = 8
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + b"\xe2\x4a\x33" * width for _ in range(height))
    idat = zlib.compress(raw, 9)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", idat)
        + chunk(b"IEND", b"")
    )


PNG_DATA = make_png()
UUID_B64 = base64.b64encode(CUSTOM_ICON_UUID.bytes).decode()


def add_icons_group(kp) -> None:
    group = kp.add_group(kp.root_group, "Icons")
    custom_entry = kp.add_entry(
        group,
        "Custom Badge",
        "icon-custom-user",
        "IconCustomSecret1",
        url=ICON_CUSTOM_URL,
    )
    kp.add_entry(group, "Plain Entry", "icon-plain-user", "IconPlainSecret2")

    meta = kp.tree.find("Meta")
    icons = etree.SubElement(meta, "CustomIcons")
    icon = etree.SubElement(icons, "Icon")
    etree.SubElement(icon, "UUID").text = UUID_B64
    etree.SubElement(icon, "Data").text = base64.b64encode(PNG_DATA).decode()

    etree.SubElement(custom_entry._element, "CustomIconUUID").text = UUID_B64


# --------------------------------------------------------------------------
# Projects / Empty Tags Group / Plain Group -- group <Tags> (was
# compatibility/group-tags.kdbx)
#
# Group tags exist only in KDBX >= 4.1, and KeeForge parses them READ-ONLY (it
# never authors or edits one), so they must come from an independent
# implementation. These groups cover every `<Tags>` state the parser models:
#
# * `Projects` -- `<Tags>team;shared</Tags>` plus a group `<Notes>`, so a real
#   file exercises two structured siblings and the unknown-sibling positioning
#   around them;
# * `Projects/Client Work` -- nested tagged group (`billable`) whose entry also
#   carries its own entry tag, for inheritance accumulation;
# * `Empty Tags Group` -- an EMPTY `<Tags/>` element (present but contentless,
#   the state `hasTagsElement` exists to preserve);
# * `Plain Group` -- no `<Tags>` element at all (KeeForge must never add one).
#
# pykeepass writes the group tag text `;`-separated (KeePass's canonical form),
# so the fixture also exercises the parser's semicolon split. pykeepass has no
# group-tag API (`tags` exists on entries only), so the `<Tags>` elements are
# inserted with lxml directly on each group's backing element, at KeePass's
# canonical position.
# --------------------------------------------------------------------------

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
EXPECTED_GROUP_TAG_ENTRIES = {
    "Alpha Login": ("alpha-user", "GroupTagAlpha1", None),
    "Beta Login": ("beta-user", "GroupTagBeta2", ["own-tag"]),
    "Gamma Login": ("gamma-user", "GroupTagGamma3", None),
    "Delta Login": ("delta-user", "GroupTagDelta4", None),
    "Trashed Login": ("trashed-user", "GroupTagTrashed5", None),
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


def add_group_tag_groups(kp) -> None:
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

    set_group_tags(projects, "team;shared")
    set_group_tags(client_work, "billable")
    set_group_tags(empty_tags_group, "")  # empty element: <Tags/>
    # Plain Group: no element at all.


# --------------------------------------------------------------------------
# Attachments -- the binary pool (was compatibility/attachments.kdbx)
#
# That fixture never had a generator; its bytes were recovered from the file and
# are embedded verbatim below. The three SHA-256 hashes are pinned in
# `KeeForgeTests/KDBXCompatibilitySupport.AttachmentFixtureHashes`, so the bytes
# are not free to drift.
# --------------------------------------------------------------------------

NOTE_NAME = "note-ü.txt"
NOTE_DATA = "KeeForge attachment fixture note with unicode filename: café, ü, ✓\n".encode()
PIXEL_NAME = "pixel.png"
PIXEL_DATA = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c63f8cfc0f01f00050502005fc8f1d2"
    "0000000049454e44ae426082"
)
SHARED_NAME = "shared.bin"
SHARED_DATA = b"Shared attachment payload used by two different entries for dedup testing.\n"

EXPECTED_ATTACHMENT_HASHES = {
    NOTE_NAME: "bcc1c6cd101bd5b27356a7004361fd1e1ff74ed2ef416e3252997d328efd3727",
    PIXEL_NAME: "3ec322a42990a3067cc6c73f3856a86e55bdd8baf19d2166954a8fb319329a72",
    SHARED_NAME: "fd184a4f05cf3d4f39ab726bda3d3a923da30e9ab2d6697b69c2d39d7ea1ab18",
}

# title -> (username, password, url, notes, [attachment names]). `Dedup Entry A`
# and `Dedup Entry B` attach the SAME pool binary, which is what gives the
# fixture its pool-dedup coverage.
ATTACHMENT_ENTRIES = {
    "Multi Attachment Entry": (
        "multi-user",
        "entry-password-1",
        "https://multi.example.com",
        "Entry with two attachments",
        [NOTE_NAME, PIXEL_NAME],
    ),
    "Dedup Entry A": (
        "dedupA-user",
        "entry-password-2",
        "https://dedupa.example.com",
        "Dedup entry A",
        [SHARED_NAME],
    ),
    "Dedup Entry B": (
        "dedupB-user",
        "entry-password-3",
        "https://dedupb.example.com",
        "Dedup entry B",
        [SHARED_NAME],
    ),
    "No Attachment Entry": (
        "plain-user",
        "entry-password-4",
        "https://plain.example.com",
        "Entry with no attachments",
        [],
    ),
}


def add_attachments_group(kp) -> None:
    """The `Attachments` group, with one pool binary per distinct payload."""
    binary_ids = {
        name: kp.add_binary(data, protected=False)
        for name, data in (
            (NOTE_NAME, NOTE_DATA),
            (PIXEL_NAME, PIXEL_DATA),
            (SHARED_NAME, SHARED_DATA),
        )
    }

    group = kp.add_group(kp.root_group, "Attachments")
    for title, (username, password, url, notes, names) in ATTACHMENT_ENTRIES.items():
        entry = kp.add_entry(group, title, username, password, url=url, notes=notes)
        for name in names:
            entry.add_attachment(binary_ids[name], name)


# --------------------------------------------------------------------------
# Recycle Bin and the 4.1 header
# --------------------------------------------------------------------------


def add_recycle_bin(kp) -> None:
    """Trashing creates the Recycle Bin group and sets Meta/RecycleBinUUID, so
    the fixture carries a real bin: deleting an entry must reuse it rather than
    author a new one. The bin itself deliberately gets no tags -- recycle-bin
    tag exclusion is covered by in-memory unit tests (DatabaseViewModelTests)."""
    trashed = kp.add_entry(kp.root_group, "Trashed Login", "trashed-user", "GroupTagTrashed5")
    kp.trash_entry(trashed)


def raise_to_kdbx41(kp) -> None:
    """KDBX 4.1 is the version that introduced group tags.

    pykeepass writes KDBX 4.0 with no public setter for the format version, so
    the minor version is bumped by mutating the low-level Construct header
    container directly; the cache drop that makes the mutation reach the file is
    explained in `_common.drop_rawcopy_cache`."""
    kp.kdbx.header.value.minor_version = 1
    drop_rawcopy_cache(kp)


def build(path: Path) -> None:
    kp = new_database(path, PASSWORD)

    add_tagged_groups(kp)
    add_secrets_group(kp)
    add_icons_group(kp)
    add_group_tag_groups(kp)
    add_attachments_group(kp)
    add_recycle_bin(kp)  # last under the root

    raise_to_kdbx41(kp)
    kp.save()


# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------


def verify_kdbx41_header(path: Path, kp) -> str:
    """Assert the raw header says 4.1 and return the KDF's name."""
    header = parse_outer_header(path.read_bytes())
    if (header.major, header.minor) != (4, 1):
        raise AssertionError(
            f"{path.name}: expected raw header version 4.1, got {header.major}.{header.minor}"
        )
    if kp.version != (4, 1):
        raise AssertionError(f"{path.name}: pykeepass reports version {kp.version}, expected (4, 1)")

    # NOTE: kp.kdf_algorithm is unusable here -- pykeepass 4.1.1 only maps the
    # KDF name for versions (3, 1) and exactly (4, 0), returning None for 4.1.
    kdf_uuid = kdf_parameters(header)["$UUID"]
    kdf_name = KDF_NAMES.get(kdf_uuid)
    if kdf_name is None:
        raise AssertionError(f"{path.name}: unrecognized KDF UUID {kdf_uuid.hex()}")
    return kdf_name


def verify_root_groups(path: Path, kp) -> None:
    expected = [
        "Tagged",
        "Archive",
        "Secrets",
        "Icons",
        "Projects",
        "Empty Tags Group",
        "Plain Group",
        "Attachments",
        kp.recyclebin_group.name,
    ]
    actual = [group.name for group in kp.root_group.subgroups]
    if actual != expected:
        raise AssertionError(f"{path.name}: root groups {actual!r}, expected {expected!r}")
    if kp.root_group.entries:
        raise AssertionError(
            f"{path.name}: nothing may sit directly under the root, found "
            f"{[entry.title for entry in kp.root_group.entries]!r}"
        )
    print(f"  root groups: {actual!r}")


def verify_tagged_groups(path: Path, kp) -> dict[str, int]:
    """Check every group/entry `add_tagged_groups` wrote; return the histogram."""
    seen: dict[str, int] = {}
    for group_name, entry_specs in TAGGED_GROUPS.items():
        group = kp.find_groups(name=group_name, first=True)
        if group is None:
            raise AssertionError(f"{path.name}: group {group_name!r} missing")
        for spec in entry_specs:
            entry = kp.find_entries(title=spec["title"], first=True)
            if entry is None:
                raise AssertionError(f"{path.name}: entry {spec['title']!r} missing")
            if entry.username != spec["username"] or entry.password != spec["password"]:
                raise AssertionError(f"{path.name}: {spec['title']} credentials drifted")
            tags = entry.tags or []
            if tags != spec["tags"]:
                raise AssertionError(
                    f"{path.name}: {spec['title']} tags {tags!r}, expected {spec['tags']!r}"
                )
            for tag in tags:
                seen[tag] = seen.get(tag, 0) + 1
    return seen


def assert_protected_field(path: Path, entry, key: str, value: str, label: str) -> None:
    """Assert `entry` carries `key` = `value` with `Protected="True"` -- read
    off the XML, since pykeepass decrypts protected values transparently and so
    cannot tell a protected field from a plaintext one."""
    field = next(
        (
            string
            for string in entry._element.findall("String")
            if string.find("Key").text == key
        ),
        None,
    )
    if field is None:
        raise AssertionError(f"{path.name}: {label} is missing the {key!r} custom field")
    if field.find("Value").text != value:
        raise AssertionError(f"{path.name}: {label} custom field value drifted")
    if field.find("Value").get("Protected") != "True":
        raise AssertionError(f"{path.name}: {label} custom field is not protected")


def verify_secrets_group(path: Path, kp) -> None:
    entry = kp.find_entries(title=PROTECTED_TITLE, first=True)
    if entry is None:
        raise AssertionError(f"{path.name}: entry {PROTECTED_TITLE!r} missing")
    assert_protected_field(
        path, entry, PROTECTED_FIELD_KEY, PROTECTED_FIELD_VALUE, "current entry"
    )
    if len(entry.history) != 1:
        raise AssertionError(
            f"{path.name}: expected 1 history version, found {len(entry.history)}"
        )
    assert_protected_field(
        path, entry.history[0], PROTECTED_FIELD_KEY, PROTECTED_FIELD_VALUE, "history entry"
    )
    if entry.notes != PROTECTED_NOTES:
        raise AssertionError(f"{path.name}: {PROTECTED_TITLE!r} notes drifted: {entry.notes!r}")

    totp = kp.find_entries(title=TOTP_TITLE, first=True)
    if totp is None:
        raise AssertionError(f"{path.name}: entry {TOTP_TITLE!r} missing")
    if totp.username != TOTP_USERNAME or totp.password != TOTP_PASSWORD:
        raise AssertionError(f"{path.name}: entry {TOTP_TITLE!r} credential mismatch")
    if totp.group.name != "Secrets":
        raise AssertionError(f"{path.name}: {TOTP_TITLE!r} is not in 'Secrets'")
    if totp.otp != TOTP_FIELD_VALUE:
        raise AssertionError(f"{path.name}: {TOTP_TITLE!r} otp field drifted: {totp.otp!r}")
    assert_protected_field(path, totp, TOTP_FIELD_KEY, TOTP_FIELD_VALUE, TOTP_TITLE)

    titles = [child.title for child in entry.group.entries]
    if titles != [PROTECTED_TITLE, TOTP_TITLE]:
        raise AssertionError(f"{path.name}: 'Secrets' entry order {titles!r}")
    print(f"  'Secrets': protected custom field in entry and history, order {titles!r}")


def verify_icons_group(path: Path, kp) -> None:
    icons = kp.tree.findall("Meta/CustomIcons/Icon")
    if len(icons) != 1:
        raise AssertionError(f"{path.name}: expected 1 custom icon, found {len(icons)}")
    if icons[0].findtext("UUID") != UUID_B64:
        raise AssertionError(f"{path.name}: custom icon UUID drifted")
    if base64.b64decode(icons[0].findtext("Data")) != PNG_DATA:
        raise AssertionError(f"{path.name}: custom icon image bytes drifted")

    custom_entry = kp.find_entries(title="Custom Badge", first=True)
    if custom_entry is None:
        raise AssertionError(f"{path.name}: 'Custom Badge' entry missing")
    if custom_entry._element.findtext("CustomIconUUID") != UUID_B64:
        raise AssertionError(f"{path.name}: 'Custom Badge' does not reference the custom icon")
    if custom_entry.url != ICON_CUSTOM_URL:
        raise AssertionError(f"{path.name}: 'Custom Badge' URL drifted: {custom_entry.url!r}")

    plain_entry = kp.find_entries(title="Plain Entry", first=True)
    if plain_entry is None:
        raise AssertionError(f"{path.name}: 'Plain Entry' entry missing")
    if plain_entry._element.findtext("CustomIconUUID") is not None:
        raise AssertionError(f"{path.name}: 'Plain Entry' must not use a custom icon")
    if plain_entry.url:
        raise AssertionError(f"{path.name}: 'Plain Entry' must have no URL, got {plain_entry.url!r}")
    if plain_entry.history:
        raise AssertionError(f"{path.name}: 'Plain Entry' must ship no stored history")
    print(f"  custom icon {CUSTOM_ICON_UUID} ({len(PNG_DATA)}-byte PNG) on 'Custom Badge'")


def verify_group_tags(path: Path, kp) -> None:
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

    projects = kp.find_groups(name="Projects", first=True)
    if projects.notes != PROJECTS_NOTES:
        raise AssertionError(f"{path.name}: 'Projects' group notes drifted: {projects.notes!r}")

    recyclebin = kp.recyclebin_group
    if recyclebin is None:
        raise AssertionError(f"{path.name}: recycle bin group missing")
    print(f"  recycle bin: {recyclebin.name!r} with {len(recyclebin.entries)} entry(ies)")

    for title, (username, password, tags) in EXPECTED_GROUP_TAG_ENTRIES.items():
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


def verify_attachments(path: Path, kp) -> None:
    for title, (username, password, url, notes, names) in ATTACHMENT_ENTRIES.items():
        entry = kp.find_entries(title=title, first=True)
        if entry is None:
            raise AssertionError(f"{path.name}: entry {title!r} missing")
        if entry.username != username or entry.password != password:
            raise AssertionError(f"{path.name}: entry {title!r} credential mismatch")
        if (entry.url or "") != url or (entry.notes or "") != notes:
            raise AssertionError(f"{path.name}: entry {title!r} url/notes drifted")

        actual = [attachment.filename for attachment in entry.attachments]
        if actual != names:
            raise AssertionError(
                f"{path.name}: entry {title!r} attachments {actual!r}, expected {names!r}"
            )
        for attachment in entry.attachments:
            digest = hashlib.sha256(attachment.binary).hexdigest()
            expected = EXPECTED_ATTACHMENT_HASHES[attachment.filename]
            if digest != expected:
                raise AssertionError(
                    f"{path.name}: {title!r} attachment {attachment.filename!r} "
                    f"sha256 {digest}, expected {expected}"
                )
        print(f"  entry {title!r}: attachments={actual!r}")

    dedup_refs = {
        title: kp.find_entries(title=title, first=True)._element.find("Binary/Value").get("Ref")
        for title in ("Dedup Entry A", "Dedup Entry B")
    }
    if len(set(dedup_refs.values())) != 1:
        raise AssertionError(
            f"{path.name}: the dedup entries must share one pool binary, got {dedup_refs!r}"
        )
    if len(kp.binaries) != 3:
        raise AssertionError(f"{path.name}: expected a 3-item binary pool, got {len(kp.binaries)}")
    print(f"  binary pool: {len(kp.binaries)} items, dedup ref shared ({dedup_refs['Dedup Entry A']})")


def verify_keepassxc_cli(path: Path, keepassxc_cli: str) -> None:
    verify_keepassxc_lists_group(path, keepassxc_cli, PASSWORD, "Attachments")

    for entry_path, expected_password in (
        ("Attachments/Multi Attachment Entry", "entry-password-1"),
        ("Projects/Alpha Login", "GroupTagAlpha1"),
    ):
        result = run_keepassxc_cli(
            keepassxc_cli, ["show", "-q", "-s", "-a", "Password", str(path), entry_path], PASSWORD
        )
        if result.returncode != 0:
            raise AssertionError(
                f"keepassxc-cli show {entry_path!r} failed:\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )
        actual = result.stdout.rstrip("\r\n")
        if actual != expected_password:
            raise AssertionError(
                f"keepassxc-cli returned password {actual!r} for {entry_path!r}, "
                f"expected {expected_password!r}"
            )
        print(f"  keepassxc-cli show -s -a Password {entry_path!r}: {actual!r} (matches)")

    for entry_path, name, expected_data in (
        ("Attachments/Multi Attachment Entry", NOTE_NAME, NOTE_DATA),
        ("Attachments/Multi Attachment Entry", PIXEL_NAME, PIXEL_DATA),
        ("Attachments/Dedup Entry A", SHARED_NAME, SHARED_DATA),
        ("Attachments/Dedup Entry B", SHARED_NAME, SHARED_DATA),
    ):
        with tempfile.TemporaryDirectory() as export_dir:
            export_path = f"{export_dir}/exported"
            result = run_keepassxc_cli(
                keepassxc_cli,
                ["attachment-export", "-q", str(path), entry_path, name, export_path],
                PASSWORD,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"keepassxc-cli attachment-export {entry_path}/{name} failed:\n"
                    f"stdout: {result.stdout}\nstderr: {result.stderr}"
                )
            exported = Path(export_path).read_bytes()
            digest = hashlib.sha256(exported).hexdigest()
            if exported != expected_data or digest != EXPECTED_ATTACHMENT_HASHES[name]:
                raise AssertionError(
                    f"keepassxc-cli exported {entry_path}/{name} with sha256 {digest}"
                )
            print(f"  keepassxc-cli attachment-export {entry_path}/{name}: sha256 {digest} (matches)")


def verify(path: Path, keepassxc_cli: str | None) -> None:
    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    kdf_name = verify_kdbx41_header(path, kp)
    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, kdf={kdf_name}, "
        f"sha256={hashlib.sha256(path.read_bytes()).hexdigest()}"
    )

    verify_root_groups(path, kp)
    entry_tag_counts = verify_tagged_groups(path, kp)
    verify_secrets_group(path, kp)
    verify_icons_group(path, kp)
    verify_group_tags(path, kp)
    verify_attachments(path, kp)

    entry_tag_counts["own-tag"] = 1  # on Beta Login, checked by verify_group_tags
    if entry_tag_counts != EXPECTED_ENTRY_TAG_COUNTS:
        raise AssertionError(
            f"{path.name}: entry tag counts {entry_tag_counts!r}, "
            f"expected {EXPECTED_ENTRY_TAG_COUNTS!r}"
        )
    # The app's tag browser merges entry tags with every ancestor group's tags,
    # which is why its `shared` count reads 4, not the 2 here.
    print(f"  entry tags: {entry_tag_counts}")

    if keepassxc_cli:
        verify_keepassxc_cli(path, keepassxc_cli)
    else:
        print("  (skipping keepassxc-cli verification -- no --keepassxc-cli path given)")


GENERATORS = [
    Generator(
        name="kitchen-sink",
        output_path=fixture_path("kitchen-sink.kdbx"),
        build=build,
        verify=verify,
    )
]
