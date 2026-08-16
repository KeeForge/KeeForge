"""`compatibility/argon2-high-iterations.kdbx` -- a KDBX4 fixture whose Argon2
KDF uses a HIGH iteration count with LOW memory (issue #74).

KeeForge used to reject any Argon2 configuration with iterations > 1000
regardless of memory, which broke real databases tuned for high iterations and
modest memory. The replacement `KDFExecutionPolicy` budgets total work
(memory x iterations) instead, so this fixture pins the acceptance case:

    iterations = 1500, memory = 1 MiB, parallelism = 1
    (total work = 1.5 GiB -- well inside every policy budget, and cheap enough
    for the repeated derivations the compatibility matrix performs)

pykeepass has no public API for KDF parameters (`create_database` accepts none),
so the Argon2 values are changed by mutating the parsed variant dictionary in
the low-level Construct header container directly; pykeepass re-derives its
transformed key from that same dictionary on `save()`, so the mutated values
govern both the written header and the encryption. The cache drop that makes
the mutation reach the file is explained in `_common.drop_rawcopy_cache`.
"""

import hashlib
from pathlib import Path

from ._common import (
    ARGON2D_UUID,
    Generator,
    drop_rawcopy_cache,
    fixture_path,
    kdf_parameters,
    new_database,
    parse_outer_header,
    pykeepass,
    verify_keepassxc_lists_group,
)

PASSWORD = "argon2-high-iterations"

# Above KeeForge's retired fixed 1000-iteration cap; 1.5 GiB of total work.
KDF_ITERATIONS = 1500
KDF_MEMORY_BYTES = 1 * 1024 * 1024
KDF_PARALLELISM = 1

GROUP_NAME = "High Iterations"
# Pinned by KDBXCompatibilitySupport.fixtureEntryPasswords (the keepassxc-cli
# probe) and TestFixtures/README.md -- change all three together.
ENTRY_TITLE = "High Iteration Entry"
ENTRY_USERNAME = "high-iteration-user"
ENTRY_PASSWORD = "HighIterationSecret1"


def build(path: Path) -> None:
    kp = new_database(path, PASSWORD)

    kdf = kp.kdbx.header.value.dynamic_header.kdf_parameters.data.dict
    kdf["I"].value = KDF_ITERATIONS
    kdf["M"].value = KDF_MEMORY_BYTES
    kdf["P"].value = KDF_PARALLELISM
    drop_rawcopy_cache(kp)

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


def verify(path: Path, keepassxc_cli: str | None) -> None:
    raw = path.read_bytes()
    header = parse_outer_header(raw)
    if header.major != 4:
        raise AssertionError(f"{path.name}: expected KDBX 4.x, got {header.major}.{header.minor}")

    kdf = kdf_parameters(header)
    expected = {
        "$UUID": ARGON2D_UUID,
        "I": KDF_ITERATIONS,
        "M": KDF_MEMORY_BYTES,
        "P": KDF_PARALLELISM,
    }
    for key, want in expected.items():
        got = kdf.get(key)
        if got != want:
            raise AssertionError(
                f"{path.name}: KDF {key!r} mismatch (expected {want!r}, got {got!r})"
            )

    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
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
        verify_keepassxc_lists_group(path, keepassxc_cli, PASSWORD, GROUP_NAME)


GENERATORS = [
    Generator(
        name="argon2-high-iterations",
        output_path=fixture_path("compatibility", "argon2-high-iterations.kdbx"),
        build=build,
        verify=verify,
    )
]
