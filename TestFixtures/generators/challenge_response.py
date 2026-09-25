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

pykeepass knows nothing about hardware keys, so the KDF is run here from that
composite and handed to pykeepass as a precomputed `transformed_key`; pykeepass
writes the salt it was given and never rotates it. The HMAC secret is a test
constant -- `KeeForgeTests` emulates a YubiKey programmed with it.

`challenge-response-aeskdf.kdbx` is the same database keyed with the KDBX 4
AES-KDF: KeePassXC folds the response in before whichever KDF is selected, and
issues the AES-KDF seed (`S`) as the challenge the same way.
"""

import hashlib
import hmac
from pathlib import Path

import argon2
from Cryptodome.Cipher import AES

from ._common import (
    AESKDF_UUID,
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
AES_KDF_ROUNDS = 1000

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


def composite_key(salt: bytes) -> bytes:
    response = yubikey_response(padded_challenge(salt))
    return hashlib.sha256(
        hashlib.sha256(PASSWORD.encode("utf-8")).digest() + hashlib.sha256(response).digest()
    ).digest()


def transformed_key(salt: bytes) -> bytes:
    composite = composite_key(salt)
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


def aes_transformed_key(seed: bytes) -> bytes:
    transformed = composite_key(seed)
    cipher = AES.new(seed, AES.MODE_ECB)
    for _ in range(AES_KDF_ROUNDS):
        transformed = cipher.encrypt(transformed)
    return hashlib.sha256(transformed).digest()


def build(path: Path) -> None:
    kp = new_database(path, PASSWORD)

    kdf = kp.kdbx.header.value.dynamic_header.kdf_parameters.data.dict
    kdf["I"].value = KDF_ITERATIONS
    kdf["M"].value = KDF_MEMORY_BYTES
    kdf["P"].value = KDF_PARALLELISM
    kdf["V"].value = 0x13
    drop_rawcopy_cache(kp)

    add_entry(kp)
    kp.save(transformed_key=transformed_key(kdf["S"].value))


def build_aes_kdf(path: Path) -> None:
    kp = new_database(path, PASSWORD)

    kdf = kp.kdbx.header.value.dynamic_header.kdf_parameters.data.dict
    kdf["$UUID"].value = AESKDF_UUID
    # The template's Argon2 `I` (UInt64) becomes the AES-KDF round count `R`.
    rounds = kdf.pop("I")
    rounds.key = "R"
    rounds.value = AES_KDF_ROUNDS
    for name in ("M", "P", "V"):
        del kdf[name]
    kdf["R"] = rounds
    # Each item's `next_byte` peeks at the following item's type; 0 ends the
    # dictionary, and the build refuses a list that never ends.
    items = list(kdf.values())
    for item, following in zip(items, items[1:] + [None]):
        item.next_byte = following.type if following else 0
    drop_rawcopy_cache(kp)

    add_entry(kp)
    kp.save(transformed_key=aes_transformed_key(kdf["S"].value))


def add_entry(kp) -> None:
    group = kp.add_group(kp.root_group, GROUP_NAME)
    kp.add_entry(
        group,
        ENTRY_TITLE,
        ENTRY_USERNAME,
        ENTRY_PASSWORD,
        notes="pykeepass-authored fixture entry (see TestFixtures/README.md)",
    )


def verify(path: Path, keepassxc_cli: str | None) -> None:
    verify_fixture(path, ARGON2D_UUID, transformed_key, keepassxc_cli)


def verify_aes_kdf(path: Path, keepassxc_cli: str | None) -> None:
    verify_fixture(path, AESKDF_UUID, aes_transformed_key, keepassxc_cli)


def verify_fixture(path: Path, kdf_uuid: bytes, derive, keepassxc_cli: str | None) -> None:
    raw = path.read_bytes()
    header = parse_outer_header(raw)
    if header.major != 4:
        raise AssertionError(f"{path.name}: expected KDBX 4.x, got {header.major}.{header.minor}")

    kdf = kdf_parameters(header)
    if kdf.get("$UUID") != kdf_uuid:
        raise AssertionError(f"{path.name}: unexpected KDF {kdf.get('$UUID')!r}")
    salt = kdf["S"]

    try:
        pykeepass.PyKeePass(str(path), password=PASSWORD)
    except pykeepass.exceptions.CredentialsError:
        pass
    else:
        raise AssertionError(f"{path.name}: opened with the password alone")

    kp = pykeepass.PyKeePass(str(path), transformed_key=derive(salt))
    entry = kp.find_entries(title=ENTRY_TITLE, first=True)
    if entry is None:
        raise AssertionError(f"{path.name}: entry {ENTRY_TITLE!r} missing after reload")
    if entry.username != ENTRY_USERNAME or entry.password != ENTRY_PASSWORD:
        raise AssertionError(f"{path.name}: entry {ENTRY_TITLE!r} credential mismatch after reload")

    parameters = " ".join(f"{name}={kdf[name]}" for name in ("I", "M", "P", "R") if name in kdf)
    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, {parameters}, "
        f"sha256={hashlib.sha256(raw).hexdigest()}"
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
    ),
    Generator(
        name="challenge-response-aeskdf",
        output_path=fixture_path("challenge-response-aeskdf.kdbx"),
        build=build_aes_kdf,
        verify=verify_aes_kdf,
    ),
]
