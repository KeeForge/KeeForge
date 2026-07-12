# Slice 02: KDBX Write and Cipher Routing

> Parent: [`epic.md`](./epic.md) · Depends on: 01

## Goal

Recognize Twofish as a supported KDBX outer cipher, open representative KDBX 3.1/4.x files, and preserve Twofish when writing KDBX 4.x files while leaving creation defaults and legacy write policy unchanged.

## Scope

**In:**

- Add the standard Twofish UUID and a single outer-cipher routing abstraction used by parser, writer, IV sizing, and diagnostics.
- Decrypt KDBX 4.x Twofish after existing header and block-HMAC validation.
- Encrypt KDBX 4.x Twofish when reusing a parsed Twofish header.
- Decrypt KDBX 3.1 Twofish while preserving read-only behavior.
- Preserve KDBX 4 minor version, KDF, compression, protected-field stream, attachments, protected values, and unknown outer-header/XML data on save.
- Add three sanitized external fixtures and focused parser/writer/diagnostic tests.

**Out:**

- The full edit matrix, persistence-service matrix, AutoFill save matrix, and external artifact expansion in Slice 03.
- KDBX 3.1 writing, cipher conversion, or a cipher chooser.
- Padding fallback, streaming, or changes to KDF algorithms.

## Implementation requirements

### Shared cipher routing

- Define one internal representation for AES-256-CBC, ChaCha20, and Twofish-256-CBC. It owns UUID matching, display name, IV length, format support, and encrypt/decrypt dispatch.
- Unknown UUIDs still throw `KDBXCrypto.CryptoError.unsupportedCipher` with the hex UUID and remain classified as `format.unsupported_cipher`.
- AES uses a 16-byte IV, ChaCha20 a 12-byte nonce, and Twofish a 16-byte IV. Route validation to the algorithm implementation; do not normalize malformed IVs by truncation.
- The routing source is in `KeeForge/Models` and must compile unchanged in the main app and AutoFill extension.

### KDBX 4 read/write behavior

- Preserve the existing order: parse header, derive keys, verify header HMAC, read and verify all HMAC blocks, then decrypt through the selected cipher. A tampered authenticated block must never reach Twofish or padding validation.
- Treat Twofish decryption/padding failures as the same generic authentication/decryption failure used for AES; do not reveal padding detail.
- Reused headers preserve `formatVersion`, `cipherID`, KDF variant/parameters, compression flag, inner stream ID/key, inner binaries, and unknown outer fields. The writer generates fresh IV/master seed and existing fresh material where required without changing the selected cipher.
- Fix the current writer's unconditional gzip behavior: compression flag 0 writes uncompressed inner-header + XML bytes and remains 0 in the header; flag 1 gzips and remains 1. Reject unsupported flag values rather than rewriting them.
- Twofish writer output uses strict PKCS#7, a fresh 16-byte IV, existing KDBX 4 HMAC framing, and the original Twofish UUID.
- Fresh database creation remains AES-256-CBC with the existing default KDF/compression. Do not expose Twofish through `DatabaseCreationService` or UI.

### KDBX 3.1 read-only behavior

- Allow AES or Twofish in the legacy parser; all other UUIDs remain unsupported.
- Derive the existing AES-KDF master key, decrypt Twofish-CBC, verify stream-start bytes in constant time, then process hashed blocks, gzip, and the configured protected-field stream exactly as today.
- Normalize strict-padding failure and stream-start mismatch to the existing invalid-credentials/open error. Wrong credentials must count as a failed attempt; a valid but unknown cipher must not.
- Keep `FileVersion.requiresReadOnlyMode == true`, and keep every `KDBXWriter` entry point rejecting a KDBX 3.1 source before serialization.

### Diagnostics

- Render the known UUID as `Twofish-256-CBC` for both KDBX 3.1 and 4.x header summaries.
- Do not include key material, IVs, ciphertext, plaintext, protected fields, attachment bytes, or full file hashes in diagnostics.
- Existing AES/ChaCha names and unsupported-cipher classification remain unchanged.

## Fixtures

Create and sanitize these fixtures with KeePassXC; record creator version, exact settings, credentials, expected entries/attachments, and SHA-256 in `TestFixtures/README.md`:

1. `twofish-kdbx40-argon2d.kdbx`: KDBX 4.0, Twofish, Argon2d, iterations 3, memory 16 MiB, parallelism 4, gzip, password `twofish-report`. Include group `Twofish`, entry `Report Profile`, username `report-user`, protected password `report-secret`, and URL `https://twofish.example`. This reproduces the reported profile without retaining the reporter's database or secrets.
2. `twofish-kdbx41-argon2id-keyfile.kdbx` plus `twofish-kdbx41-argon2id-keyfile.keyx`: KDBX 4.1, Twofish, Argon2id v1.3 with iterations 4, memory 32 MiB, parallelism 2, password `twofish-keyfile`, key-file format v2, compression disabled, group `Rich Twofish`, entry `Key File Entry`, protected password `keyfile-secret`, a protected custom field, attachments `twofish-note.txt` containing `KeeForge Twofish compatibility fixture\n` and `twofish-data.bin` containing bytes `00...FF`, and deterministic KDBX 4.1 public custom data containing `KeeForgeTwofishFixture`.
3. `twofish-kdbx31-aeskdf.kdbx`: KDBX 3.1, Twofish, AES-KDF with 100,000 rounds, Salsa20 protected fields, gzip, password `twofish-legacy`. Include group `Legacy Twofish` and entry `Legacy Entry` with protected password `legacy-secret`.

Fixtures are test resources only. Never commit the original reported file, its password, diagnostic hash, or derived artifacts.

## Affected areas

- New: shared outer-cipher routing model; three sanitized database fixtures and one fixture key file.
- Modified: stable KDBX crypto/parser/writer files, database-open diagnostics, parser/writer tests, test-fixture documentation.
- Unchanged: database creation UI/service default, storage services, cloud providers, and AutoFill UI.

## KeeForge bits

- **Targets:** outer-cipher routing and modified `KeeForge/Models` files belong to both `KeeForge` and `KeeForgeAutoFill`; `DatabaseOpenFailure.swift` belongs to `KeeForge`; tests and fixture resources belong to `KeeForgeTests` only.
- **project.yml:** add the three `.kdbx` fixtures and key file as `KeeForgeTests` resources. Slice 01's local package dependencies remain on the main app, AutoFill, and tests. Run `xcodegen generate`.
- **Accessibility identifiers:** N/A — no view-layer work.

## Testing

### Unit: `KDBXParserTests.swift`

- Open each fixture with correct credentials and assert expected entry/group/protected-field/attachment content.
- Assert file version, Twofish UUID, KDF UUID and exact parameters, compression flag, IV length, protected stream, unknown outer fields, and inner binary count.
- KDBX 3.1 asserts read-only mode and Salsa20 protected values; attempting writer reuse throws `unsupportedSourceFormat`.
- Wrong password and wrong/missing key file fail as authentication without returning parsed data.
- Mutating a KDBX 4 header HMAC or encrypted HMAC block fails before the test-only Twofish decrypt spy is invoked.
- Authenticated ciphertext with deliberately valid HMACs but invalid PKCS#7 fails generically; unknown cipher UUID remains unsupported format.
- Header diagnostics identify Twofish by name for KDBX 3.1 and 4.x.

### Unit: `KDBXWriterTests.swift`

- Reuse each KDBX 4 fixture header, make a deterministic small edit, write, reparse, and assert the edit plus all preserved header/KDF/compression/stream/attachment/protection/unknown-data properties.
- Assert the Twofish output header UUID, a fresh 16-byte IV different from the source, block-aligned ciphertext, valid header/payload HMACs, and successful independent decryption/reparse.
- The no-compression fixture remains uncompressed and parseable; the gzip fixture remains gzip.
- AES and ChaCha20 encrypted-container tests remain unchanged and pass.
- Fresh-header creation remains AES and its current IV/KDF/compression defaults remain unchanged.

### Unit: `DatabaseViewModelTests.swift`

- Opening the reported-profile fixture succeeds and diagnostics show `Twofish-256-CBC`.
- KDBX 3.1 Twofish enters the same read-only state as the existing AES legacy fixture.
- Authentication, tamper, and unsupported-format classifications retain their failed-attempt semantics.

Run:

```bash
xcodegen generate
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/KDBXParserTests \
  -only-testing:KeeForgeTests/KDBXWriterTests \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

### Integration / UI

N/A — integration save routes are Slice 03; no UI behavior changes.

### Manual

- Open sanitized copies of all three fixtures in KeeForge and compare their visible records/protected values with KeePassXC.
- Make one edit to each KDBX 4 fixture, save, and open the result in KeePassXC; confirm its database settings still show Twofish and the original KDF/compression choices.
- Confirm the KDBX 3.1 fixture is visibly read-only and no save action writes it.

## Exit criteria

- [ ] The three fixture profiles open with correct content and metadata.
- [ ] Both KDBX 4 fixtures save/reparse with Twofish and exact supported-property preservation.
- [ ] KDBX 3.1 Twofish opens read-only and writer reuse is rejected.
- [ ] HMAC tamper is rejected before decrypt; strict padding and wrong credentials expose no plaintext.
- [ ] Diagnostics say `Twofish-256-CBC`; unknown ciphers remain unsupported.
- [ ] AES, ChaCha20, and fresh AES-creation regression tests pass.
- [ ] Main app and AutoFill compile with shared routing under strict concurrency; heavy crypto remains off main.
- [ ] Fixture provenance is documented and `project.yml` resources are regenerated with `xcodegen generate`.
- [ ] Replace Slice 01's CHANGELOG line with the progressive entry below under `## Unreleased`.

## CHANGELOG entry

Replace the Slice 01 entry with; Slice 03 will replace this with the final wording:

`- Added support for opening Twofish-encrypted KDBX 3.1 and 4.x databases and preserving Twofish when saving KDBX 4.x databases.`
