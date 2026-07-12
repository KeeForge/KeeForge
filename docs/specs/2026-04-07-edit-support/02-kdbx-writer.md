# Slice 02: KDBX writer (encryption, framing, HMAC)

> Parent: [`epic.md`](./epic.md) · Depends on: 01

## Goal

Add a `KDBXWriter` that takes a parsed tree (root `KPGroup` + `KPMeta` from slice 01) plus a composite key plus the original KDBX header parameters, and produces fully-formed KDBX 4.x file bytes that any KeePass-compatible client can re-open. After this slice, parse → write → parse on every TestFixture is a complete identity, including HMAC verification.

This slice still ships no user-visible feature; it makes the encrypted file format reversible.

## Scope

**In:**

- A new `KDBXWriter` enum that mirrors the structure of `KDBXParser`, in reverse:
  1. Build the outer header from the existing `Header` (or, for new databases, from a fresh `Header` populated with new IVs and seeds).
  2. Use slice 01's serializer to produce the XML payload.
  3. Build the inner header (random stream id + key + binary entries — for round-trip we re-use the same inner stream).
  4. Optionally gzip the inner header + XML payload (always gzip on write to match KeePassXC's default).
  5. Encrypt with the configured cipher (AES-256-CBC or ChaCha20-Poly1305) using the existing `KDBXCrypto` helpers.
  6. Frame the ciphertext into HMAC blocks identical to the read path's `readHMACBlocks` (per-block HMAC over `(blockIndex, blockSize, blockData)`).
  7. Compute and prepend the outer-header SHA-256 and outer-header HMAC.
- New writer-side helpers in `KDBXCrypto.swift`: `encryptAES256CBC(data:key:iv:)`, `encryptChaCha20Poly1305(data:key:nonce:)`, and `gzip(_ data: Data)`. These are the symmetric counterparts of the existing `decryptAES256CBC`, `decryptChaCha20Poly1305`, `gunzip`. No changes to existing functions.
- Variant-map writer for KDF parameters (the read-side `parseVariantMap` exists at `KDBXParser.swift:303`; we need its inverse).
- Fresh-IV / fresh-master-seed generation paths for "new database" mode. v1 reuses the existing IVs and seeds for round-trip writes (the user is editing an existing file, so we can keep the seeds). For brand-new databases, we'd generate fresh ones — but creating a *new* database is out of scope for this epic, so the writer should at minimum support both modes for forward compatibility, and slice 02 only exercises the "reuse existing header" mode.

**Out:**

- The atomic file write to disk, backups, conflict detection — slice 04.
- Any cloud upload — slice 05.
- Any UI for triggering the write — slice 06.
- Any code path for creating a *new* database from scratch (including generating new seeds, choosing KDF parameters, choosing master password). The writer must accept "fresh header" inputs at the API surface, but the slice does not ship a caller for that mode.

## Affected areas

- **New:** `KeeForge/Models/KDBXWriter.swift`.
- **Modified:** `KeeForge/Models/KDBXCrypto.swift` — adds `encryptAES256CBC`, `encryptChaCha20Poly1305`, `gzip` (the inverses of existing helpers). Pure additions.
- **Modified:** `KeeForge/Models/KDBXParser.swift` — extract the existing `Header` struct and `HeaderField` / `InnerHeaderField` enums from `private` to `internal` so `KDBXWriter` can reuse them. No behavior change.
- **New tests:** `KeeForgeTests/KDBXWriterTests.swift`.

## KeeForge bits

- **Targets:** `KDBXWriter.swift` belongs to **both** `KeeForge` and `KeeForgeAutoFill` via the existing `KeeForge/Models` glob path. New helpers in `KDBXCrypto.swift` inherit the same membership.
- **project.yml:**
  - No changes — `KeeForge/Models` is already a glob path on both targets.
  - `Run xcodegen generate` is not needed.
- **Accessibility identifiers:** N/A — no view layer.

## Testing

- **Unit:** `KeeForgeTests/KDBXWriterTests.swift`
  - `test_writeRoundTrip_test_kdbx_AES_returnsEqualTree` — open `test.kdbx`, write, re-open the freshly written bytes with the original password, assert the resulting tree is equal to the original (entries, groups, recycle bin, custom fields, TOTP, passkey, unknown nodes from slice 01).
  - `test_writeRoundTrip_demo_kdbx_returnsEqualTree` — same for `demo.kdbx`.
  - `test_writeRoundTrip_demoKeyfile_kdbx_returnsEqualTree` — same with key file authentication path.
  - `test_writtenFile_validatesOuterHeaderHMAC` — confirm the read path's HMAC verification (`KDBXParser.swift:158–164`) accepts the freshly written file.
  - `test_writtenFile_validatesPerBlockHMAC` — write a database with payload large enough to span multiple HMAC blocks (e.g., add a few KB of fake notes content); confirm `readHMACBlocks` accepts every block.
  - `test_writeWithChaCha20Cipher_roundTrip` — pick a fixture that uses ChaCha20-Poly1305 (or build one in test setup) and assert round-trip succeeds.
  - `test_writer_failsOnInvalidKDFParameters` — pass `iterations: 0`, `memory: 0`; assert the writer rejects with the same `kdfParameterOutOfRange` semantics the parser uses.
  - `test_writeAndDecrypt_protectedValueStaysOpaque` — write a tree, decrypt the resulting bytes manually, assert the protected `<Value Protected="True">` element is not the plaintext password.
  - Run slice: `xcodebuild test -only-testing:KeeForgeTests/KDBXWriterTests`.
- **Integration / UI:** N/A.
- **Manual:**
  - Take the bytes produced by one of the round-trip tests, write them to a temp file, open in KeePassXC on macOS (or KeePass2Android), confirm the database opens with the original password and the entries look identical.
- **Edge cases that apply:**
  - Database with an empty root group (no entries, no subgroups).
  - Database whose recycle bin contains entries (recycle bin UUID needs to round-trip via `KPMeta`).
  - Database with `<History>` blocks per entry — every historical revision must round-trip.
  - Database with binary attachments referenced from the inner header.
  - Argon2id vs Argon2d KDF — both must round-trip via the variant-map writer.
  - AES-256-CBC vs ChaCha20-Poly1305 outer cipher — both must round-trip.

## Exit criteria

- [ ] All round-trip unit tests pass on every fixture under `TestFixtures/`.
- [ ] At least one freshly written file opens cleanly in KeePassXC on macOS (manual check).
- [ ] No force unwraps. `KDBXWriter` is an `enum` of static functions (matches the parser's style).
- [ ] All encryption / KDF / serialization runs off the main actor.
- [ ] Existing parser/crypto tests pass unchanged.
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG entry

`- Internal: KDBX writer can now produce KDBX 4.x files (AES-256-CBC and ChaCha20-Poly1305) for use by upcoming edit features.`
