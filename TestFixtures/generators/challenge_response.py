"""`challenge-response.kdbx` -- a KDBX4 fixture whose composite key includes a
YubiKey HMAC-SHA1 challenge-response, the way KeePassXC builds it (issue #62).

KeePassXC (`CompositeKey::rawKey(transformSeed)` / `CompositeKey::transform`)
issues the KDF salt as the challenge and folds the answer into the key that
goes into the KDF:

    composite = SHA256( SHA256(password) || SHA256(response) )

The challenge is the salt PKCS#7-padded to 64 bytes
(`YubiKeyInterfaceUSB::challenge`). A slot in variable-length mode -- the
`ykman otp chalresp` default -- strips trailing bytes equal to the last byte
before computing the HMAC, which is what `yubikey_response` emulates, so the
response here is HMAC-SHA1 over the bare 32-byte salt.

pykeepass knows nothing about hardware keys, so the Argon2d transform is run
here from that composite and handed to pykeepass as a precomputed
`transformed_key`; pykeepass writes the salt it was given and never rotates it.
The HMAC secret is a test constant -- `KeeForgeTests` emulates a YubiKey
programmed with it.
"""

import hashlib
import hmac
from pathlib import Path

import argon2

from ._common import (
    ARGON2D_UUID,
    Generator,
    drop_rawcopy_cache,
    fixture_path,
    kdf_parameters,
    new_database,
    parse_outer_header,
    pykeepass,
)

PASSWORD = "challenge-response"
# Mirrored by ChallengeResponseFixture in KeeForgeTests -- change both together.
HMAC_SECRET = b"KeeForgeYubiKeyTest!"

KDF_ITERATIONS = 2
KDF_MEMORY_BYTES = 1 * 1024 * 1024
KDF_PARALLELISM = 1

GROUP_NAME = "Hardware Key"
ENTRY_TITLE = "YubiKey Entry"
ENTRY_USERNAME = "yubikey-user"
ENTRY_PASSWORD = "YubiKeySecret1"


def padded_challenge(seed: bytes) -> bytes:
    pad = 64 - len(seed)
    return seed + bytes([pad]) * pad if pad > 0 else seed


def yubikey_response(challenge: bytes) -> bytes:
    last = challenge[-1]
    end = len(challenge)
    while end > 0 and challenge[end - 1] == last:
        end -= 1
    return hmac.new(HMAC_SECRET, challenge[:end], hashlib.sha1).digest()


def transformed_key(salt: bytes) -> bytes:
    response = yubikey_response(padded_challenge(salt))
    composite = hashlib.sha256(
        hashlib.sha256(PASSWORD.encode("utf-8")).digest() + hashlib.sha256(response).digest()
    ).digest()
    return argon2.low_level.hash_secret_raw(
        secret=composite,
        salt=salt,
        hash_len=32,
        type=argon2.low_level.Type.D,
        time_cost=KDF_ITERATIONS,
        memory_cost=KDF_MEMORY_BYTES // 1024,
        parallelism=KDF_PARALLELISM,
        version=0x13,
    )


def build(path: Path) -> None:
    kp = new_database(path, PASSWORD)

    kdf = kp.kdbx.header.value.dynamic_header.kdf_parameters.data.dict
    kdf["I"].value = KDF_ITERATIONS
    kdf["M"].value = KDF_MEMORY_BYTES
    kdf["P"].value = KDF_PARALLELISM
    kdf["V"].value = 0x13
    drop_rawcopy_cache(kp)

    group = kp.add_group(kp.root_group, GROUP_NAME)
    kp.add_entry(
        group,
        ENTRY_TITLE,
        ENTRY_USERNAME,
        ENTRY_PASSWORD,
        notes="pykeepass-authored fixture entry (see TestFixtures/README.md)",
    )

    kp.save(transformed_key=transformed_key(kdf["S"].value))


def verify(path: Path, keepassxc_cli: str | None) -> None:
    raw = path.read_bytes()
    header = parse_outer_header(raw)
    if header.major != 4:
        raise AssertionError(f"{path.name}: expected KDBX 4.x, got {header.major}.{header.minor}")

    kdf = kdf_parameters(header)
    if kdf.get("$UUID") != ARGON2D_UUID:
        raise AssertionError(f"{path.name}: expected an Argon2d KDF")
    salt = kdf["S"]

    try:
        pykeepass.PyKeePass(str(path), password=PASSWORD)
    except pykeepass.exceptions.CredentialsError:
        pass
    else:
        raise AssertionError(f"{path.name}: opened with the password alone")

    kp = pykeepass.PyKeePass(str(path), transformed_key=transformed_key(salt))
    entry = kp.find_entries(title=ENTRY_TITLE, first=True)
    if entry is None:
        raise AssertionError(f"{path.name}: entry {ENTRY_TITLE!r} missing after reload")
    if entry.username != ENTRY_USERNAME or entry.password != ENTRY_PASSWORD:
        raise AssertionError(f"{path.name}: entry {ENTRY_TITLE!r} credential mismatch after reload")

    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, kdf=argon2d "
        f"I={kdf['I']} M={kdf['M']} P={kdf['P']}, sha256={hashlib.sha256(raw).hexdigest()}"
    )
    print(f"  entry {ENTRY_TITLE!r}: username={ENTRY_USERNAME!r}")

    if keepassxc_cli:
        print("  keepassxc-cli: skipped, opening needs a hardware key")


GENERATORS = [
    Generator(
        name="challenge-response",
        output_path=fixture_path("challenge-response.kdbx"),
        build=build,
        verify=verify,
    )
]
