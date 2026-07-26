# Slice 01: One ChaCha20 Implementation + Salsa20 Vectors

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

Exactly one ChaCha20 block-function implementation exists in the codebase — the RFC-vector-tested one in `KDBXCrypto` — and the KDBX3 Salsa20 inner stream gains known-answer-vector coverage.

## Scope

**In:**
- Replace the private ChaCha20 block functions in `KDBXParser` (legacy inner-stream decode path) and `KDBXXMLSerializer` (protected-field re-encryption on write) with calls into `KDBXCrypto`'s implementation. Byte-identical output is the acceptance bar; this is a pure consolidation, not a behavior change.
- Expose whatever minimal internal surface `KDBXCrypto` needs for those two call sites (e.g. a keystream/block primitive) without weakening its API discipline; keep everything `internal`, nothing public.
- New known-answer tests that pin the *shared* implementation through each consumer's key-derivation convention (KDBX4 protected stream: SHA-512 of the stream key → ChaCha20 key + nonce). Include plaintext lengths straddling block boundaries (e.g. 63/64/65 bytes and a multi-block run) to catch counter/offset bugs, plus a cross-check that parser-side decrypt of serializer-side encrypt round-trips through the shared primitive.
- Salsa20 known-answer-vector tests for the KDBX3 inner stream in `KDBXParser` (production code unchanged): standard ECRYPT/eSTREAM vectors where the fixed KDBX Salsa20 nonce convention allows, otherwise vectors derived from an independent implementation, pinned with a provenance comment.

**Out:** any change to Salsa20 production code; any change to outer-cipher (AES/ChaCha20/Twofish container) code paths; performance work.

## Affected areas

- Modified: `KeeForge/Models/KDBXCrypto.swift`, `KeeForge/Models/KDBXParser.swift`, `KeeForge/Models/KDBXXMLSerializer.swift` (deletions of the duplicate block functions + call-site rewiring), `KeeForgeTests/ChaCha20Tests.swift`, `KeeForgeTests/KDBXParserTests.swift` (Salsa20 vectors, or a new small test file if cleaner).

## KeeForge bits

- **Targets:** all three model files are shared across `KeeForge`, `KeeForgeMac`, `KeeForgeAutoFill`, `KeeForgeMacAutoFill` — keep extension-safe imports (no UIKit/AppKit). Test files compile into `KeeForgeTests` + `KeeForgeMacTests`.
- **project.yml:** No changes expected (folder globs; only if a new test file is added does anything change, and even then only `xcodegen generate`). Run `xcodegen generate` if files are added.
- **Accessibility identifiers:** N/A — no view code.

## Testing

- **Unit:** `ChaCha20Tests.swift` — shared-primitive vectors through the protected-stream key-derivation convention; block-boundary lengths; serializer-encrypt → parser-decrypt equivalence. `KDBXParserTests.swift` (or new file) — Salsa20 known-answer vectors for the KDBX3 inner stream; existing KDBX3 fixture (`test-v3-backup.kdbx`) still decodes its protected values.
  Run slice: `-only-testing:KeeForgeTests/ChaCha20Tests -only-testing:KeeForgeTests/KDBXParserTests -only-testing:KeeForgeTests/KDBXRoundTripTests -only-testing:KeeForgeTests/KDBXWriterTests -only-testing:KeeForgeTests/KDBXCompatibilityTests`
- **Integration:** run `ci_scripts/run_kdbx_compatibility_gate.sh` locally — its 22 external protected-password checks are the designed safety net for exactly this refactor and must stay green.
- **Manual:** open an existing KDBX4 database, reveal a password; save an edit, reopen in KeePassXC and reveal the same password; open the KDBX3 fixture and reveal a protected value.
- **Edge cases that apply:** empty protected value, multi-block (>64-byte) protected value, database with many protected values (stream offset accumulation), locked-DB behavior unchanged.

## Exit criteria

- [ ] Unit tests above pass on iOS and macOS test targets.
- [ ] Local compatibility gate passes (21 artifacts, 22 password checks — unchanged counts).
- [ ] The two duplicate block functions are deleted, not deprecated; `grep` finds one ChaCha20 quarter-round in the repo.
- [ ] Manual checks done.
- [ ] No force unwraps; secrets stay behind `EncryptedValue`; heavy work off main.

## CHANGELOG entry

`N/A — no user-visible behavior change (internal crypto consolidation); the epic's entry lands with slice 02.`
