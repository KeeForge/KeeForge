#!/usr/bin/env python3
"""Generate `argon2-high-iterations.kdbx`, the KDBX4 fixture whose Argon2 KDF
uses a HIGH iteration count with LOW memory (issue #74).

KeeForge used to reject any Argon2 configuration with iterations > 1000
regardless of memory, which broke real databases tuned for high iterations
and modest memory. The replacement `KDFExecutionPolicy` budgets total work
(memory x iterations) instead, so this fixture pins the acceptance case:

    iterations = 1500, memory = 1 MiB, parallelism = 1
    (total work = 1.5 GiB -- well inside every policy budget, and cheap
    enough for the repeated derivations the compatibility matrix performs)

Authored with pykeepass, an independent implementation, so the compatibility
gate proves KeeForge opens and rewrites a foreign file with these settings,
and `keepassxc-cli` proves another foreign implementation reads KeeForge's
rewrite of it.

Requires: pykeepass (`pip3 install --user pykeepass`). Verified against
pykeepass 4.1.1.post1 -- re-check the two API assumptions below if a newer
pykeepass changes its internals:

1. pykeepass has no public API for KDF parameters (`create_database` accepts
   none). The Argon2 values are changed by mutating the parsed variant
   dictionary in the low-level Construct header container directly:
   `kp.kdbx.header.value.dynamic_header.kdf_parameters.data.dict` -- pykeepass
   re-derives its transformed key from that same dictionary on `save()`, so
   the mutated values govern both the written header and the encryption.
2. That header is wrapped in Construct's `RawCopy`, which caches the
   originally-parsed header bytes under a `data` key and re-emits them
   verbatim on build, IGNORING mutations to `value` -- so after changing the
   KDF values, `del kp.kdbx.header["data"]` is required or the saved file's
   declared header silently keeps the defaults while the payload is encrypted
   with the mutated ones (an unopenable file). Same mechanism documented in
   `generate_foreign_cipher_fixtures.py`; see `construct.RawCopy._build`.

Output is deterministic in CONTENT (group, entry, credentials, KDF values)
but NOT in bytes: pykeepass generates a fresh master seed, encryption IV, and
KDF salt on every `save()`. Tests assert decoded content, not raw bytes.

Usage (from the repo root):

    python3 TestFixtures/compatibility/generate_argon2_high_iterations_fixture.py          # regenerate
    python3 TestFixtures/compatibility/generate_argon2_high_iterations_fixture.py --check  # verify only

Pass `--keepassxc-cli /path/to/keepassxc-cli` to additionally verify the file
opens with KeePassXC (a second foreign reader).
"""

import argparse
import hashlib
import struct
import subprocess
import sys
from pathlib import Path

try:
    import pykeepass
except ImportError:
    raise SystemExit(
        "pykeepass is required: pip3 install --user pykeepass "
        "(or install it into a venv and re-run with that interpreter)"
    )

OUTPUT_PATH = Path(__file__).resolve().parent / "argon2-high-iterations.kdbx"
PASSWORD = "argon2-high-iterations"

# Above KeeForge's retired fixed 1000-iteration cap; 1.5 GiB of total work.
KDF_ITERATIONS = 1500
KDF_MEMORY_BYTES = 1 * 1024 * 1024
KDF_PARALLELISM = 1

ARGON2D_UUID = bytes.fromhex("ef636ddf8c29444b91f7a9a403e30a0c")

GROUP_NAME = "High Iterations"
# Pinned by KDBXCompatibilitySupport.fixtureEntryPasswords (the keepassxc-cli
# probe) and TestFixtures/README.md -- change all three together.
ENTRY_TITLE = "High Iteration Entry"
ENTRY_USERNAME = "high-iteration-user"
ENTRY_PASSWORD = "HighIterationSecret1"


def build_fixture(path: Path) -> None:
    kp = pykeepass.create_database(str(path), password=PASSWORD)

    kdf = kp.kdbx.header.value.dynamic_header.kdf_parameters.data.dict
    kdf["I"].value = KDF_ITERATIONS
    kdf["M"].value = KDF_MEMORY_BYTES
    kdf["P"].value = KDF_PARALLELISM
    # See module docstring point 2: drop the cached raw header bytes so the
    # builder re-serializes from the mutated values.
    del kp.kdbx.header["data"]

    group = kp.add_group(kp.root_group, GROUP_NAME)
    kp.add_entry(
        group,
        ENTRY_TITLE,
        ENTRY_USERNAME,
        ENTRY_PASSWORD,
        url="https://high-iterations.example.com",
        notes="pykeepass-authored fixture entry (see TestFixtures/README.md)",
    )

    kp.save()


def parse_kdf_variant_dict(path: Path) -> dict:
    """Independently parse the outer header's KDF variant dictionary without
    pykeepass, so verification doesn't just trust the library that wrote it."""
    data = path.read_bytes()
    sig1, sig2, minor, major = struct.unpack_from("<IIHH", data, 0)
    if (sig1, sig2) != (0x9AA2D903, 0xB54BFB67):
        raise ValueError(f"{path}: bad KDBX signature")
    if major != 4:
        raise ValueError(f"{path}: expected KDBX 4.x, got {major}.{minor}")

    offset = 12
    kdf_blob = None
    while True:
        field_id = data[offset]
        (size,) = struct.unpack_from("<I", data, offset + 1)
        value = data[offset + 5 : offset + 5 + size]
        offset += 5 + size
        if field_id == 0:
            break
        if field_id == 0x0B:  # KDF parameters
            kdf_blob = value
    if kdf_blob is None:
        raise ValueError(f"{path}: no KDF parameters field in outer header")

    (dict_version,) = struct.unpack_from("<H", kdf_blob, 0)
    if dict_version & 0xFF00 != 0x0100:
        raise ValueError(f"{path}: unsupported variant dictionary version {dict_version:#x}")

    entries = {}
    pos = 2
    while True:
        value_type = kdf_blob[pos]
        pos += 1
        if value_type == 0x00:
            break
        (key_len,) = struct.unpack_from("<I", kdf_blob, pos)
        pos += 4
        key = kdf_blob[pos : pos + key_len].decode()
        pos += key_len
        (value_len,) = struct.unpack_from("<I", kdf_blob, pos)
        pos += 4
        raw = kdf_blob[pos : pos + value_len]
        pos += value_len
        if value_type == 0x04:  # UInt32
            entries[key] = struct.unpack("<I", raw)[0]
        elif value_type == 0x05:  # UInt64
            entries[key] = struct.unpack("<Q", raw)[0]
        else:
            entries[key] = raw
    return entries


def verify(path: Path, keepassxc_cli: str | None) -> None:
    kdf = parse_kdf_variant_dict(path)
    expected = {
        "$UUID": ARGON2D_UUID,
        "I": KDF_ITERATIONS,
        "M": KDF_MEMORY_BYTES,
        "P": KDF_PARALLELISM,
    }
    for key, want in expected.items():
        got = kdf.get(key)
        if got != want:
            raise AssertionError(f"{path.name}: KDF {key!r} mismatch (expected {want!r}, got {got!r})")

    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    entry = kp.find_entries(title=ENTRY_TITLE, first=True)
    if entry is None:
        raise AssertionError(f"{path.name}: entry {ENTRY_TITLE!r} missing after reload")
    if entry.username != ENTRY_USERNAME or entry.password != ENTRY_PASSWORD:
        raise AssertionError(f"{path.name}: entry {ENTRY_TITLE!r} credential mismatch after reload")

    sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, kdf=argon2d "
        f"I={kdf['I']} M={kdf['M']} P={kdf['P']}, sha256={sha256}"
    )
    print(f"  entry {ENTRY_TITLE!r}: username={ENTRY_USERNAME!r}")

    if keepassxc_cli:
        result = subprocess.run(
            [keepassxc_cli, "ls", str(path)],
            input=PASSWORD + "\n",
            capture_output=True,
            text=True,
            check=True,
        )
        if GROUP_NAME + "/" not in result.stdout:
            raise AssertionError(
                f"{path.name}: keepassxc-cli ls did not list {GROUP_NAME!r}: {result.stdout!r}"
            )
        print(f"  keepassxc-cli ls: OK ({GROUP_NAME!r} listed)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the existing fixture on disk instead of regenerating it",
    )
    parser.add_argument(
        "--keepassxc-cli",
        help="path to keepassxc-cli for an additional external-reader verification",
    )
    args = parser.parse_args()

    print(f"pykeepass version: {getattr(pykeepass, '__version__', 'unknown')}", file=sys.stderr)

    if not args.check:
        build_fixture(OUTPUT_PATH)
    verify(OUTPUT_PATH, args.keepassxc_cli)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
