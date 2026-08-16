"""`compatibility/foreign-chacha20.kdbx` and `compatibility/foreign-twofish.kdbx`
-- foreign-authored KDBX4 fixtures with non-AES outer ciphers.

Every other bundled KDBX fixture uses the AES-256-CBC outer cipher, so
KeeForge's ChaCha20 and Twofish outer-cipher READ paths had only ever been
tested against files KeeForge itself wrote (self-consistency, not ecosystem
compatibility). pykeepass authors both databases here, so KDBXParserTests can
prove KeeForge decodes a foreign author's ChaCha20 and Twofish payloads (and,
since the inner protected-value stream is independent of the outer cipher, this
also cross-validates the inner-stream decode against a foreign author for both).

`PyKeePass.encryption_algorithm` is READ-ONLY, so the outer cipher is changed by
mutating the low-level Construct header container directly; the cache drop that
makes the mutation reach the file is explained in `_common.drop_rawcopy_cache`.
Skipping it yields a file whose header still declares AES while the payload is
encrypted with the new cipher, which `verify` explicitly checks for.

Both fixtures carry IDENTICAL group, entry, and field content -- only the
database password and outer cipher differ -- so a single set of parser-test
expectations describes both.
"""

import hashlib
import os
from functools import partial
from pathlib import Path

from ._common import (
    AES256_CIPHER_UUID,
    CHACHA20_CIPHER_UUID,
    TWOFISH_CIPHER_UUID,
    Generator,
    drop_rawcopy_cache,
    fixture_path,
    new_database,
    parse_outer_header,
    pykeepass,
    verify_keepassxc_lists_group,
)

GROUP_NAME = "Foreign"
ENTRIES = [
    {
        "title": "Foreign Entry Alpha",
        "username": "foreign-alpha-user",
        "password": "ForeignAlphaSecret1",
        "url": "https://foreign-alpha.example.com",
        "notes": "pykeepass-authored fixture entry (see TestFixtures/README.md)",
        "custom_fields": {"ForeignField": "ForeignFieldValue"},
    },
    {
        "title": "Foreign Entry Beta",
        "username": "foreign-beta-user",
        "password": "ForeignBetaSecret2",
        "url": "https://foreign-beta.example.com",
        "notes": "pykeepass-authored fixture entry (see TestFixtures/README.md)",
        "custom_fields": {},
    },
]

CIPHER_UUIDS = {
    "chacha20": CHACHA20_CIPHER_UUID,
    "twofish": TWOFISH_CIPHER_UUID,
    "aes256": AES256_CIPHER_UUID,
}

FIXTURES = [
    {"name": "foreign-chacha20", "password": "foreign-chacha20", "cipher": "chacha20"},
    {"name": "foreign-twofish", "password": "foreign-twofish", "cipher": "twofish"},
]


def build(path: Path, *, password: str, cipher: str) -> None:
    kp = new_database(path, password)

    dynamic_header = kp.kdbx.header.value.dynamic_header
    dynamic_header.cipher_id.data = cipher
    # ChaCha20 needs a 12-byte nonce; AES/Twofish CBC need a 16-byte IV.
    dynamic_header.encryption_iv.data = os.urandom(12 if cipher == "chacha20" else 16)
    drop_rawcopy_cache(kp)

    group = kp.add_group(kp.root_group, GROUP_NAME)
    for entry_spec in ENTRIES:
        entry = kp.add_entry(
            group,
            entry_spec["title"],
            entry_spec["username"],
            entry_spec["password"],
            url=entry_spec["url"],
            notes=entry_spec["notes"],
        )
        for key, value in entry_spec["custom_fields"].items():
            entry.set_custom_property(key, value, protect=False)

    kp.save()


def verify(path: Path, keepassxc_cli: str | None, *, password: str, cipher: str) -> None:
    raw = path.read_bytes()
    header = parse_outer_header(raw)
    if (header.major, header.minor) != (4, 0):
        raise AssertionError(f"{path.name}: expected KDBX 4.0, got {header.major}.{header.minor}")

    cipher_uuid = header.fields.get(2)
    expected_uuid = CIPHER_UUIDS[cipher]
    if cipher_uuid != expected_uuid:
        raise AssertionError(
            f"{path.name}: expected cipher UUID {expected_uuid.hex()} ({cipher}), "
            f"got {cipher_uuid.hex() if cipher_uuid else None}"
        )
    if cipher_uuid == AES256_CIPHER_UUID and cipher != "aes256":
        raise AssertionError(
            f"{path.name}: header still declares AES -- cache-drop step was skipped"
        )

    # Also open it back up with pykeepass to confirm content round-trips and the
    # library's own view of the cipher/KDF agrees.
    kp = pykeepass.PyKeePass(str(path), password=password)
    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, "
        f"cipher={kp.encryption_algorithm} (UUID {cipher_uuid.hex()}), "
        f"kdf={kp.kdf_algorithm}, sha256={hashlib.sha256(raw).hexdigest()}"
    )
    for entry_spec in ENTRIES:
        entry = kp.find_entries(title=entry_spec["title"], first=True)
        if entry is None:
            raise AssertionError(f"{path.name}: entry {entry_spec['title']!r} missing after reload")
        if entry.password != entry_spec["password"]:
            raise AssertionError(f"{path.name}: {entry.title} password mismatch after reload")

    if keepassxc_cli:
        verify_keepassxc_lists_group(path, keepassxc_cli, password, GROUP_NAME)


GENERATORS = [
    Generator(
        name=spec["name"],
        output_path=fixture_path("compatibility", f"{spec['name']}.kdbx"),
        build=partial(build, password=spec["password"], cipher=spec["cipher"]),
        verify=partial(verify, password=spec["password"], cipher=spec["cipher"]),
    )
    for spec in FIXTURES
]
