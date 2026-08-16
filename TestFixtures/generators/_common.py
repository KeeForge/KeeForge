"""Shared plumbing for the fixture generators.

Every fixture here is authored with pykeepass -- an implementation independent
of KeeForge -- so the parser tests and the compatibility gate prove KeeForge
reads foreign files rather than only its own. Output is deterministic in
CONTENT but NOT in bytes: pykeepass generates a fresh master seed, encryption
IV, and KDF salt on every `save()`, so regenerating a fixture always changes
the file. Tests assert decoded content, never raw bytes.

Verified against pykeepass 4.1.1.post1.
"""

import argparse
import struct
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import NamedTuple

try:
    import pykeepass
except ImportError:
    raise SystemExit(
        "pykeepass is required: pip3 install --user pykeepass "
        "(or install it into a venv and re-run with that interpreter)"
    )

FIXTURES_DIR = Path(__file__).resolve().parent.parent

# KeeForge's own constants (KeeForge/Models/KDBXParser.swift), duplicated here
# so verification double-checks pykeepass's mapping against KeeForge's values
# instead of trusting either implementation alone.
AES256_CIPHER_UUID = bytes.fromhex("31c1f2e6bf714350be5805216afc5aff")
CHACHA20_CIPHER_UUID = bytes.fromhex("d6038a2b8b6f4cb5a524339a31dbb59a")
TWOFISH_CIPHER_UUID = bytes.fromhex("ad68f29f576f4bb9a36ad47af965346c")
ARGON2D_UUID = bytes.fromhex("ef636ddf8c29444b91f7a9a403e30a0c")
ARGON2ID_UUID = bytes.fromhex("9e298b1956db4773b23dfc3ec6f0a1e6")
AESKDF_UUID = bytes.fromhex("c9d9f39a628a4460bf740d08c18a4fea")

KDBX_SIGNATURE = (0x9AA2D903, 0xB54BFB67)
KDF_PARAMETERS_FIELD_ID = 0x0B


@dataclass(frozen=True)
class Generator:
    """One registered fixture: where it lives and how to author and check it."""

    name: str
    output_path: Path
    build: Callable[[Path], None]
    verify: Callable[[Path, str | None], None]


def fixture_path(*parts: str) -> Path:
    """Absolute path inside `TestFixtures/`, independent of the caller's cwd."""
    return FIXTURES_DIR.joinpath(*parts)


def banner() -> None:
    print(f"pykeepass version: {getattr(pykeepass, '__version__', 'unknown')}", file=sys.stderr)


def new_database(path: Path, password: str):
    """Fresh pykeepass database at `path`, replacing any existing file."""
    path.unlink(missing_ok=True)
    return pykeepass.create_database(str(path), password=password)


def drop_rawcopy_cache(kp) -> None:
    """Make mutations to the parsed outer header actually reach the saved file.

    pykeepass exposes no public API for the outer cipher, the KDF parameters,
    or the format's minor version, so the generators mutate the low-level
    Construct container (`kp.kdbx.header.value...`) directly. That header is
    wrapped in Construct's `RawCopy`, which caches the originally-parsed bytes
    under a `data` key and re-emits them verbatim on build, IGNORING `value`
    (see `construct.RawCopy._build`). Without dropping the cache the saved file
    silently keeps the original header while the payload is written from the
    mutated values -- a cipher-mismatched, unopenable file.
    """
    del kp.kdbx.header["data"]


class OuterHeader(NamedTuple):
    major: int
    minor: int
    fields: dict[int, bytes]
    raw: bytes  # signature + version + every header field, through the terminator
    end: int  # offset of the first byte after the header


def parse_outer_header(data: bytes) -> OuterHeader:
    """Parse the KDBX outer header without pykeepass, so verification doesn't
    just trust the library that wrote the file."""
    sig1, sig2, minor, major = struct.unpack_from("<IIHH", data, 0)
    if (sig1, sig2) != KDBX_SIGNATURE:
        raise ValueError("bad KDBX signature")

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
    return OuterHeader(major, minor, fields, data[0:offset], offset)


def parse_variant_dict(blob: bytes) -> dict[str, int | bytes]:
    """Parse a KDBX4 variant dictionary (the KDF parameters blob). UInt32/UInt64
    values are decoded to `int`; every other type stays raw `bytes`."""
    (version,) = struct.unpack_from("<H", blob, 0)
    if version & 0xFF00 != 0x0100:
        raise ValueError(f"unsupported variant dictionary version {version:#x}")

    entries: dict[str, int | bytes] = {}
    pos = 2
    while True:
        value_type = blob[pos]
        pos += 1
        if value_type == 0x00:
            break
        (key_len,) = struct.unpack_from("<I", blob, pos)
        pos += 4
        key = blob[pos : pos + key_len].decode("utf-8")
        pos += key_len
        (value_len,) = struct.unpack_from("<I", blob, pos)
        pos += 4
        raw = blob[pos : pos + value_len]
        pos += value_len
        if value_type == 0x04:  # UInt32
            entries[key] = struct.unpack("<I", raw)[0]
        elif value_type == 0x05:  # UInt64
            entries[key] = struct.unpack("<Q", raw)[0]
        else:
            entries[key] = raw
    return entries


def kdf_parameters(header: OuterHeader) -> dict[str, int | bytes]:
    blob = header.fields.get(KDF_PARAMETERS_FIELD_ID)
    if blob is None:
        raise ValueError("no KDF parameters field in outer header")
    return parse_variant_dict(blob)


def run_keepassxc_cli(
    keepassxc_cli: str, args: Sequence[str], password: str
) -> subprocess.CompletedProcess:
    """Run keepassxc-cli, feeding the password on stdin. Callers check
    `returncode` themselves so they can report the tool's own stderr."""
    return subprocess.run(
        [keepassxc_cli, *args],
        input=f"{password}\n",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def verify_keepassxc_lists_group(
    path: Path, keepassxc_cli: str, password: str, group_name: str
) -> None:
    """External-reader check: KeePassXC opens the file and lists `group_name`."""
    result = run_keepassxc_cli(keepassxc_cli, ["ls", "-q", str(path)], password)
    if result.returncode != 0:
        raise AssertionError(
            f"{path.name}: keepassxc-cli ls failed:\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    if f"{group_name}/" not in result.stdout:
        raise AssertionError(
            f"{path.name}: keepassxc-cli ls did not list {group_name!r}: {result.stdout!r}"
        )
    print(f"  keepassxc-cli ls: OK ({group_name!r} listed)")


def build_parser(names: Sequence[str]) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="generate_fixtures.py",
        description="Author and verify the pykeepass-generated KDBX test fixtures.",
        epilog="fixtures: " + ", ".join(names),
    )
    parser.add_argument("names", nargs="*", metavar="NAME", help="fixtures to process")
    parser.add_argument("--all", action="store_true", help="process every registered fixture")
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the fixtures on disk instead of regenerating them",
    )
    parser.add_argument(
        "--keepassxc-cli",
        help="path to keepassxc-cli for additional external-reader verification",
    )
    parser.add_argument(
        "--output-dir",
        help="build and verify in DIR instead of the committed fixture locations",
    )
    parser.add_argument("--list", action="store_true", help="list the registered fixtures")
    return parser
