"""`compatibility/unknown-inner-header.kdbx` -- a KDBX4 fixture with spliced-in
unknown inner-header fields.

KDBX4's inner header (protected-stream ID/key, the binary pool, and a 0x00
terminator) lives INSIDE the encrypted payload, so unlike the outer-header
mutations the other generators use, splicing an item into it can't be done by
poking the parsed Construct container before save: pykeepass's own
`InnerHeaderItem.type` field is a `construct.Mapping(Byte, {0,1,2,3})` with no
default, so it raises `MappingError` the moment it tries to PARSE a type byte it
doesn't recognize -- there is no way to hand pykeepass an unknown item and have
it round-trip one back out. This is, not coincidentally, exactly the gap this
fixture exists to probe from the other side: KeePassXC's own reader
(`Kdbx4Reader::readInnerHeaderField`) has no default case either and just skips
unrecognized IDs, and that leniency is what makes this fixture openable by an
external tool at all while being unopenable by pykeepass.

So this module follows the epic's documented fallback: build a normal database
with pykeepass, then decrypt/re-encrypt the payload by hand to splice in the
unknown items, bypassing pykeepass entirely for that step. Concretely:

1. pykeepass builds and saves an ordinary KDBX4 database (AES-256-CBC, Argon2d,
   matching every other pykeepass-authored fixture in this repo). Reopening THIS
   intermediate file with pykeepass is exactly the "reopen with pykeepass"
   sanity check the other generators perform -- it's just performed before the
   splice, not after, because after the splice pykeepass can no longer read the
   file (see above; a MappingError there is the *expected*, verified outcome).
2. The saved bytes are decrypted from scratch (outer header parse, Argon2d/
   AES-KDF transform, HMAC-SHA256 block verification, AES-256-CBC decrypt, zlib
   inflate) without reusing any pykeepass internals, so this step does not
   depend on pykeepass's low-level Construct layout at all.
3. The decrypted inner-header item sequence is spliced with three unknown fields
   (ids chosen to avoid 0x00-0x03, the only IDs KDBX4 defines):
     - id 0x7F, payload `HIGH_ID_PAYLOAD` below (a recognizable, non-trivial
       ASCII marker) -- positioned after protected_stream_key, before `end`.
     - id 0x10, zero-length payload -- positioned immediately after the 0x7F
       field, same region (after protected_stream_key, before `end`).
     - id 0x21, payload `MID_POOL_PAYLOAD` below -- positioned BETWEEN the two
       binary-pool entries (the fixture has two attachments specifically so this
       position exists). KeeForge's writer is expected to normalize this to
       before-the-pool on save (see
       docs/specs/2026-07-26-kdbx-format-hardening/02-unknown-inner-header-preservation.md);
       this fixture is what lets a test observe that normalization happening.
   Native pykeepass save order is [binary, binary, protected_stream_id,
   protected_stream_key, end] (its `DynamicDict` lumps all `binary` items at
   whichever position the `binary` key first appears, which happens to be
   first), so the final on-disk sequence produced here is: [binary(alpha),
   unknown 0x21, binary(beta), protected_stream_id, protected_stream_key,
   unknown 0x7F, unknown 0x10, end].
4. The spliced plaintext is recompressed/repadded/re-encrypted with the SAME
   master seed, IV, and KDF parameters pykeepass already generated (the outer
   header is never touched), then repacked into HMAC-authenticated payload
   blocks using KDBX4's documented block format, so the result is a fully valid,
   independently-verifiable KDBX4 file.

Also requires pykeepass's transitive deps `argon2-cffi` and `pycryptodomex`,
used directly here for the from-scratch decrypt/re-encrypt.
"""

import hashlib
import hmac
import struct
import tempfile
import zlib
from pathlib import Path

import argon2
from Cryptodome.Cipher import AES
from Cryptodome.Util import Padding as CryptoPadding

from ._common import (
    AES256_CIPHER_UUID,
    AESKDF_UUID,
    ARGON2D_UUID,
    ARGON2ID_UUID,
    Generator,
    fixture_path,
    kdf_parameters,
    new_database,
    parse_outer_header,
    pykeepass,
    run_keepassxc_cli,
)

PASSWORD = "unknown-inner-header"

GROUP_NAME = "Unknown Header"
ENTRY_TITLE = "Inner Header Entry"
ENTRY_USERNAME = "unknown-header-user"
ENTRY_PASSWORD = "UnknownHeaderSecret1"
ENTRY_URL = "https://unknown-header.example.com"
ENTRY_NOTES = "pykeepass-authored fixture entry (see TestFixtures/README.md)"

ATTACHMENT_ALPHA_NAME = "alpha-attachment.txt"
ATTACHMENT_ALPHA_DATA = b"alpha attachment payload for unknown-inner-header fixture\n"
ATTACHMENT_BETA_NAME = "beta-attachment.txt"
ATTACHMENT_BETA_DATA = b"beta attachment payload for unknown-inner-header fixture\n"

# Unknown inner-header fields spliced in after the normal pykeepass save -- see
# module docstring step 3 for exact intended positions.
HIGH_ID = 0x7F
HIGH_ID_PAYLOAD = b"kdbx-format-hardening-fixture:unknown-field-0x7f-marker"
ZERO_LEN_ID = 0x10
ZERO_LEN_PAYLOAD = b""
MID_POOL_ID = 0x21
MID_POOL_PAYLOAD = b"mid-pool-unknown-field"

KNOWN_INNER_HEADER_TYPES = {0x00, 0x01, 0x02, 0x03}


# -------------------- build the base (unspliced) database --------------------


def build_base_database(path: Path) -> None:
    kp = new_database(path, PASSWORD)
    group = kp.add_group(kp.root_group, GROUP_NAME)
    entry = kp.add_entry(
        group,
        ENTRY_TITLE,
        ENTRY_USERNAME,
        ENTRY_PASSWORD,
        url=ENTRY_URL,
        notes=ENTRY_NOTES,
    )
    alpha_id = kp.add_binary(ATTACHMENT_ALPHA_DATA, protected=True)
    entry.add_attachment(alpha_id, ATTACHMENT_ALPHA_NAME)
    beta_id = kp.add_binary(ATTACHMENT_BETA_DATA, protected=True)
    entry.add_attachment(beta_id, ATTACHMENT_BETA_NAME)
    kp.save()


def verify_base_database(path: Path) -> None:
    """Reopen with pykeepass -- the "reopen with pykeepass" check applies here,
    to the pre-splice file; see module docstring for why it can't apply after."""
    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    entry = kp.find_entries(title=ENTRY_TITLE, first=True)
    if entry is None:
        raise AssertionError(f"{path.name}: entry {ENTRY_TITLE!r} missing from base build")
    if entry.username != ENTRY_USERNAME or entry.password != ENTRY_PASSWORD:
        raise AssertionError(f"{path.name}: base build entry credentials mismatch")
    attachment_names = sorted(a.filename for a in entry.attachments)
    if attachment_names != sorted([ATTACHMENT_ALPHA_NAME, ATTACHMENT_BETA_NAME]):
        raise AssertionError(f"{path.name}: base build attachments mismatch: {attachment_names}")
    print("  base build: pykeepass reopened OK, entry+2 attachments present")


# -------------------- from-scratch KDBX4 decrypt/re-encrypt --------------------
# Deliberately independent of pykeepass's Construct layout (see module
# docstring) -- this is the standalone fallback the epic calls for.


def aes_kdf(seed: bytes, rounds: int, key_composite: bytes) -> bytes:
    cipher = AES.new(seed, AES.MODE_ECB)
    transformed = key_composite
    for _ in range(rounds):
        transformed = cipher.encrypt(transformed)
    return hashlib.sha256(transformed).digest()


def derive_transformed_key(password: str, kdf_params: dict) -> bytes:
    # Matches pykeepass.kdbx_parsing.common.compute_key_composite: the password
    # is hashed once, then re-hashed with the (empty, no-keyfile) composite -- a
    # double hash, not a single sha256(password).
    key_composite = hashlib.sha256(hashlib.sha256(password.encode("utf-8")).digest()).digest()
    uuid = kdf_params["$UUID"]
    if uuid in (ARGON2D_UUID, ARGON2ID_UUID):
        return argon2.low_level.hash_secret_raw(
            secret=key_composite,
            salt=kdf_params["S"],
            time_cost=kdf_params["I"],
            memory_cost=kdf_params["M"] // 1024,
            parallelism=kdf_params["P"],
            hash_len=32,
            type=(argon2.low_level.Type.ID if uuid == ARGON2ID_UUID else argon2.low_level.Type.D),
            version=kdf_params["V"],
        )
    if uuid == AESKDF_UUID:
        return aes_kdf(kdf_params["S"], kdf_params["R"], key_composite)
    raise ValueError(f"unsupported KDF uuid {uuid.hex()}")


class Kdbx4Body:
    """Everything needed to decrypt an existing KDBX4 file and re-encrypt a
    replacement plaintext payload under the SAME outer header (master seed, IV,
    KDF params, cipher all unchanged -- only the payload content differs)."""

    def __init__(self, path: Path, password: str):
        data = path.read_bytes()
        header = parse_outer_header(data)
        fields, header_bytes, body_offset = header.fields, header.raw, header.end
        if fields[2] != AES256_CIPHER_UUID:
            raise ValueError("this script only handles the AES-256-CBC outer cipher")

        transformed_key = derive_transformed_key(password, kdf_parameters(header))
        master_seed = fields[4]
        master_key = hashlib.sha256(master_seed + transformed_key).digest()
        hmac_key_source = hashlib.sha512(master_seed + transformed_key + b"\x01").digest()

        sha256_field = data[body_offset : body_offset + 32]
        if hashlib.sha256(header_bytes).digest() != sha256_field:
            raise AssertionError("header sha256 integrity field mismatch -- corrupt header")

        cred_check_field = data[body_offset + 32 : body_offset + 64]
        outer_hmac_key = hashlib.sha512(b"\xff" * 8 + hmac_key_source).digest()
        if hmac.new(outer_hmac_key, header_bytes, hashlib.sha256).digest() != cred_check_field:
            raise AssertionError("cred_check HMAC mismatch -- wrong password or corrupt header")

        offset = body_offset + 64
        encrypted_blocks = []
        block_index = 0
        while True:
            block_hmac = data[offset : offset + 32]
            offset += 32
            (block_len,) = struct.unpack_from("<I", data, offset)
            offset += 4
            block_data = data[offset : offset + block_len]
            offset += block_len

            block_key = hashlib.sha512(struct.pack("<Q", block_index) + hmac_key_source).digest()
            expected = hmac.new(
                block_key,
                struct.pack("<Q", block_index) + struct.pack("<I", block_len) + block_data,
                hashlib.sha256,
            ).digest()
            if block_hmac != expected:
                raise AssertionError(f"payload block {block_index} HMAC mismatch")
            if block_len == 0:
                break
            encrypted_blocks.append(block_data)
            block_index += 1

        encryption_iv = fields[7]
        cipher = AES.new(master_key, AES.MODE_CBC, encryption_iv)
        padded_plaintext = cipher.decrypt(b"".join(encrypted_blocks))
        plaintext = CryptoPadding.unpad(padded_plaintext, 16)

        self.header_bytes = header_bytes
        self.sha256_field = sha256_field
        self.cred_check_field = cred_check_field
        self.master_key = master_key
        self.encryption_iv = encryption_iv
        self.hmac_key_source = hmac_key_source
        self.compressed = bool(struct.unpack("<I", fields[3])[0])

        self.raw_payload = zlib.decompress(plaintext, 16 + 15) if self.compressed else plaintext

    def rebuild(self, new_raw_payload: bytes) -> bytes:
        plaintext = zlib_compress(new_raw_payload) if self.compressed else new_raw_payload
        padded = CryptoPadding.pad(plaintext, 16)
        cipher = AES.new(self.master_key, AES.MODE_CBC, self.encryption_iv)
        encrypted = cipher.encrypt(padded)

        out = bytearray()
        out += self.header_bytes
        out += self.sha256_field
        out += self.cred_check_field

        block_index = 0
        offset = 0
        chunk_size = 2**20
        while True:
            chunk = encrypted[offset : offset + chunk_size]
            offset += chunk_size
            block_key = hashlib.sha512(
                struct.pack("<Q", block_index) + self.hmac_key_source
            ).digest()
            block_hmac = hmac.new(
                block_key,
                struct.pack("<Q", block_index) + struct.pack("<I", len(chunk)) + chunk,
                hashlib.sha256,
            ).digest()
            out += block_hmac
            out += struct.pack("<I", len(chunk))
            out += chunk
            if len(chunk) == 0:
                break
            block_index += 1

        return bytes(out)


def zlib_compress(data: bytes) -> bytes:
    compressor = zlib.compressobj(6, zlib.DEFLATED, 16 + 15, zlib.DEF_MEM_LEVEL, 0)
    return compressor.compress(data) + compressor.flush()


def parse_inner_header(raw: bytes) -> tuple[list[tuple[int, bytes]], int]:
    offset = 0
    items = []
    while True:
        type_id = raw[offset]
        offset += 1
        (length,) = struct.unpack_from("<I", raw, offset)
        offset += 4
        payload = raw[offset : offset + length]
        offset += length
        items.append((type_id, payload))
        if type_id == 0x00:
            break
    return items, offset


def serialize_inner_header(items: list[tuple[int, bytes]]) -> bytes:
    out = bytearray()
    for type_id, payload in items:
        out += struct.pack("<B", type_id)
        out += struct.pack("<I", len(payload))
        out += payload
    return bytes(out)


def splice_unknown_fields(items: list[tuple[int, bytes]]) -> list[tuple[int, bytes]]:
    binary_indices = [i for i, (t, _) in enumerate(items) if t == 0x03]
    if len(binary_indices) != 2:
        raise AssertionError(
            f"expected exactly 2 binary-pool entries in the base build, found {len(binary_indices)} "
            "-- pykeepass's inner-header lumping behavior may have changed, re-derive this "
            "module's assumptions"
        )
    if [t for t, _ in items] != [0x03, 0x03, 0x01, 0x02, 0x00]:
        raise AssertionError(
            f"unexpected base inner-header shape {[hex(t) for t, _ in items]}; "
            "expected pykeepass's native [binary, binary, protected_stream_id, "
            "protected_stream_key, end]"
        )

    binary_alpha, binary_beta, protected_stream_id, protected_stream_key, end = items
    return [
        binary_alpha,
        (MID_POOL_ID, MID_POOL_PAYLOAD),
        binary_beta,
        protected_stream_id,
        protected_stream_key,
        (HIGH_ID, HIGH_ID_PAYLOAD),
        (ZERO_LEN_ID, ZERO_LEN_PAYLOAD),
        end,
    ]


def build(path: Path) -> None:
    build_base_database(path)
    verify_base_database(path)

    body = Kdbx4Body(path, PASSWORD)
    items, inner_header_len = parse_inner_header(body.raw_payload)
    xml_bytes = body.raw_payload[inner_header_len:]

    spliced_items = splice_unknown_fields(items)
    new_raw_payload = serialize_inner_header(spliced_items) + xml_bytes

    path.write_bytes(body.rebuild(new_raw_payload))


# -------------------- verification --------------------


def verify_pykeepass_rejects_unknown_fields(path: Path) -> None:
    """The whole point of this fixture: an independent implementation with a
    strict inner-header type mapping cannot open it. Confirm that's still true
    (and still MappingError specifically), not some unrelated break."""
    try:
        pykeepass.PyKeePass(str(path), password=PASSWORD)
    except Exception as exc:  # noqa: BLE001 - deliberately broad, see below
        if type(exc).__name__ != "MappingError":
            raise AssertionError(
                f"expected pykeepass to fail with MappingError on the unknown inner-header "
                f"field, got {type(exc).__name__}: {exc}"
            )
        print(f"  pykeepass correctly refuses the spliced file: {exc}")
        return
    raise AssertionError(
        "pykeepass opened the spliced file without error -- the unknown-field splice did not "
        "take effect, this fixture no longer tests what it claims to"
    )


def verify_inner_header_sequence(path: Path) -> None:
    body = Kdbx4Body(path, PASSWORD)
    items, _ = parse_inner_header(body.raw_payload)
    expected_types = [0x03, MID_POOL_ID, 0x03, 0x01, 0x02, HIGH_ID, ZERO_LEN_ID, 0x00]
    actual_types = [t for t, _ in items]
    if actual_types != expected_types:
        raise AssertionError(
            f"inner header type sequence mismatch: expected {[hex(t) for t in expected_types]}, "
            f"got {[hex(t) for t in actual_types]}"
        )
    if items[1][1] != MID_POOL_PAYLOAD:
        raise AssertionError("mid-pool unknown field payload mismatch")
    if items[5][1] != HIGH_ID_PAYLOAD:
        raise AssertionError("0x7f unknown field payload mismatch")
    if items[6][1] != ZERO_LEN_PAYLOAD:
        raise AssertionError("zero-length unknown field payload not empty")
    unknown_count = sum(1 for t, _ in items if t not in KNOWN_INNER_HEADER_TYPES)
    if unknown_count != 3:
        raise AssertionError(
            f"expected exactly 3 unknown inner-header fields, found {unknown_count}"
        )

    print(f"  inner header sequence ({len(items)} items):")
    for index, (type_id, payload) in enumerate(items):
        marker = "" if type_id in KNOWN_INNER_HEADER_TYPES else "  <- unknown"
        print(f"    [{index}] type=0x{type_id:02x} length={len(payload)}{marker}")


def verify_keepassxc_cli(path: Path, keepassxc_cli: str) -> None:
    entry_path = f"{GROUP_NAME}/{ENTRY_TITLE}"

    result = run_keepassxc_cli(
        keepassxc_cli,
        ["show", "-q", "-s", "-a", "Password", str(path), entry_path],
        PASSWORD,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"keepassxc-cli show failed:\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
    actual_password = result.stdout.rstrip("\r\n")
    if actual_password != ENTRY_PASSWORD:
        raise AssertionError(
            f"keepassxc-cli returned password {actual_password!r}, expected {ENTRY_PASSWORD!r}"
        )
    print(f"  keepassxc-cli show -s -a Password: {actual_password!r} (matches)")

    for name, expected_data in (
        (ATTACHMENT_ALPHA_NAME, ATTACHMENT_ALPHA_DATA),
        (ATTACHMENT_BETA_NAME, ATTACHMENT_BETA_DATA),
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
                    f"keepassxc-cli attachment-export for {name!r} failed:\n"
                    f"stdout: {result.stdout}\nstderr: {result.stderr}"
                )
            exported = Path(export_path).read_bytes()
            if exported != expected_data:
                raise AssertionError(f"keepassxc-cli exported attachment {name!r} content mismatch")
            print(f"  keepassxc-cli attachment-export {name!r}: {len(exported)} bytes (matches)")


def verify(path: Path, keepassxc_cli: str | None) -> None:
    print(f"{path.name}: sha256={hashlib.sha256(path.read_bytes()).hexdigest()}")
    verify_pykeepass_rejects_unknown_fields(path)
    verify_inner_header_sequence(path)
    if keepassxc_cli:
        verify_keepassxc_cli(path, keepassxc_cli)
    else:
        print("  (skipping keepassxc-cli verification -- no --keepassxc-cli path given)")


GENERATORS = [
    Generator(
        name="unknown-inner-header",
        output_path=fixture_path("compatibility", "unknown-inner-header.kdbx"),
        build=build,
        verify=verify,
    )
]
