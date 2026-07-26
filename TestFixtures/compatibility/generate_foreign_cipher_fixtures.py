#!/usr/bin/env python3
"""Generate foreign-authored KDBX4 fixtures with non-AES outer ciphers.

Every other bundled KDBX fixture uses the AES-256-CBC outer cipher, so
KeeForge's ChaCha20 and Twofish outer-cipher READ paths have only ever been
tested against files KeeForge itself wrote (self-consistency, not ecosystem
compatibility). This script uses pykeepass -- an independent implementation
-- to author two KDBX4 databases that exercise those two ciphers, so
KDBXParserTests can prove KeeForge decodes a foreign author's ChaCha20 and
Twofish outer-cipher payloads (and, since the inner protected-value stream is
independent of the outer cipher, this also cross-validates the inner-stream
decode against a foreign author for both).

Requires: pykeepass (`pip3 install --user pykeepass`). Verified against
pykeepass 4.1.1.post1 -- re-check the two API assumptions below if a newer
pykeepass changes its internals:

1. `PyKeePass.encryption_algorithm` is READ-ONLY in 4.1.1.post1 (there is no
   `kp.encryption_algorithm = 'chacha20'` setter). The outer cipher is
   changed by mutating the low-level Construct header container directly:
   `kp.kdbx.header.value.dynamic_header.cipher_id.data`.
2. That header is wrapped in Construct's `RawCopy`, which caches the
   originally-parsed (AES) header bytes under a `data` key. Construct's
   `RawCopy._build` re-emits that cached `data` verbatim if present, IGNORING
   any mutations to `value` -- so after changing `cipher_id`/`encryption_iv`,
   `del kp.kdbx.header["data"]` is required or the saved file's declared
   header cipher silently stays AES while only the payload gets encrypted
   with the new cipher (a corrupt, cipher-mismatched file). This was
   confirmed by direct experimentation while writing this script; see
   `construct.RawCopy._build`.

Output is deterministic in CONTENT (group/entry/field names, usernames,
protected passwords) but NOT in bytes: pykeepass generates a fresh random
master seed, encryption IV, and KDF salt on every `save()`, so re-running
this script produces a different (but equally valid) file each time. That is
expected and fine -- tests assert decoded content, not raw bytes.
"""

import argparse
import hashlib
import os
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

OUTPUT_DIR = Path(__file__).resolve().parent

# Cipher UUIDs as KeeForge defines them (KeeForge/Models/KDBXParser.swift) --
# duplicated here (not imported, this is a standalone Python script) purely
# so `verify()` can double-check pykeepass's own cipher_id mapping against
# KeeForge's constants rather than trusting either implementation alone.
AES_CIPHER_UUID = bytes.fromhex("31c1f2e6bf714350be5805216afc5aff")
CHACHA20_CIPHER_UUID = bytes.fromhex("d6038a2b8b6f4cb5a524339a31dbb59a")
TWOFISH_CIPHER_UUID = bytes.fromhex("ad68f29f576f4bb9a36ad47af965346c")

# Shared, documented fixture content. Both fixtures carry IDENTICAL group,
# entry, and field content -- only the database password and outer cipher
# differ -- so a single set of parser-test expectations can describe both.
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

FIXTURES = [
    {"filename": "foreign-chacha20.kdbx", "password": "foreign-chacha20", "cipher": "chacha20"},
    {"filename": "foreign-twofish.kdbx", "password": "foreign-twofish", "cipher": "twofish"},
]


def build_fixture(path: Path, password: str, cipher: str) -> None:
    kp = pykeepass.create_database(str(path), password=password)

    dynamic_header = kp.kdbx.header.value.dynamic_header
    dynamic_header.cipher_id.data = cipher
    # ChaCha20 needs a 12-byte nonce; AES/Twofish CBC need a 16-byte IV.
    iv_length = 12 if cipher == "chacha20" else 16
    dynamic_header.encryption_iv.data = os.urandom(iv_length)
    # See module docstring point 2: drop the cached raw header bytes so the
    # builder re-serializes from our mutated `value` instead of re-emitting
    # the original AES header verbatim.
    del kp.kdbx.header["data"]

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


def parse_outer_header(path: Path) -> tuple[int, int, dict[int, bytes]]:
    """Independently parse the KDBX outer header without pykeepass, so
    verification doesn't just trust the library that wrote the file."""
    data = path.read_bytes()
    sig1, sig2, minor, major = struct.unpack_from("<IIHH", data, 0)
    if (sig1, sig2) != (0x9AA2D903, 0xB54BFB67):
        raise ValueError(f"{path}: bad KDBX signature")

    offset = 12
    fields: dict[int, bytes] = {}
    while True:
        field_id = data[offset]
        (size,) = struct.unpack_from("<I", data, offset + 1)
        value = data[offset + 5 : offset + 5 + size]
        offset += 5 + size
        if field_id == 0:
            break
        fields[field_id] = value
    return major, minor, fields


def verify(path: Path, password: str, expected_cipher: str) -> None:
    major, minor, fields = parse_outer_header(path)
    if (major, minor) != (4, 0):
        raise AssertionError(f"{path.name}: expected KDBX 4.0, got {major}.{minor}")

    cipher_uuid = fields.get(2)
    expected_uuid = {
        "chacha20": CHACHA20_CIPHER_UUID,
        "twofish": TWOFISH_CIPHER_UUID,
        "aes256": AES_CIPHER_UUID,
    }[expected_cipher]
    if cipher_uuid != expected_uuid:
        raise AssertionError(
            f"{path.name}: expected cipher UUID {expected_uuid.hex()} ({expected_cipher}), "
            f"got {cipher_uuid.hex() if cipher_uuid else None}"
        )
    if cipher_uuid == AES_CIPHER_UUID and expected_cipher != "aes256":
        raise AssertionError(f"{path.name}: header still declares AES -- cache-drop step was skipped")

    # Also open it back up with pykeepass to confirm content round-trips
    # and the library's own view of the cipher/KDF agrees.
    kp = pykeepass.PyKeePass(str(path), password=password)
    sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, "
        f"cipher={kp.encryption_algorithm} (UUID {cipher_uuid.hex()}), "
        f"kdf={kp.kdf_algorithm}, sha256={sha256}"
    )
    for entry_spec in ENTRIES:
        entry = kp.find_entries(title=entry_spec["title"], first=True)
        if entry is None:
            raise AssertionError(f"{path.name}: entry {entry_spec['title']!r} missing after reload")
        if entry.password != entry_spec["password"]:
            raise AssertionError(f"{path.name}: {entry.title} password mismatch after reload")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the existing fixtures on disk instead of regenerating them",
    )
    args = parser.parse_args()

    print(f"pykeepass version: {getattr(pykeepass, '__version__', 'unknown')}", file=sys.stderr)

    for spec in FIXTURES:
        path = OUTPUT_DIR / spec["filename"]
        if not args.check:
            build_fixture(path, spec["password"], spec["cipher"])
        verify(path, spec["password"], spec["cipher"])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
