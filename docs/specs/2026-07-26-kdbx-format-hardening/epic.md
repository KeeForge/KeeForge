# Epic: KDBX Format Hardening — ChaCha20 Consolidation + Unknown Inner-Header Preservation

## Summary

Two independent stable-core hardening changes from the 2026-07-25 test-suite audit (`docs/audits/2026-07-25-test-suite-audit.md`): collapse the three hand-rolled ChaCha20 implementations onto the single RFC-vector-tested one so a divergence bug in the cipher protecting every KDBX4 secret becomes impossible rather than merely detectable, and preserve unknown KDBX4 inner-header fields across save so a future format extension is not silently destroyed the first time KeeForge writes the file.

## Clarified requirements

- **Q:** Should the crypto-hardening slice also cover the KDBX3 legacy Salsa20 inner stream (a fourth hand-rolled cipher with zero known-answer vectors)?
  **A:** Yes — consolidate the three ChaCha20 copies AND add Salsa20 known-answer-vector tests in the same slice. No production Salsa20 change (only one copy exists).
- **Q:** What ordering contract should unknown inner-header fields get on re-save?
  **A:** Simple contract: re-emit unknown fields byte-exact, in original relative order, after the inner random stream ID/key fields and before the binary pool. Not position-stable relative to pool entries.
- **Q:** Should a synthetic unknown-inner-header fixture go through the external keepassxc-cli gate or stay at unit/matrix level?
  **A:** Matrix + external gate (artifact count grows by one), with a documented fallback to unit-only if KeePassXC rejected such files — research below shows it does not, so the gate path is expected to work.

## Research

- The KDBX 4 spec ([KDBX 4 — keepass.info](https://keepass.info/help/kb/kdbx_4.html)) defines inner-header item types 0x00 (end), 0x01 (inner random stream ID), 0x02 (inner random stream key), 0x03 (binary), terminated by a 0x00 item; it gives **no guidance on unknown item types or extensibility**.
- KeePassXC's `Kdbx4Reader::readInnerHeaderField` **silently skips** unrecognized inner-header field IDs (its switch has no default case; contrast its outer-header path, which at least logs a warning). Preserving unknown fields therefore cannot make KeeForge output unreadable to KeePassXC, and the external gate can verify files carrying one.
- ChaCha20 test vectors: [RFC 8439](https://www.rfc-editor.org/rfc/rfc8439). Salsa20 vectors: the ECRYPT/eSTREAM verified test-vector set (or vectors cross-derived from a second implementation, pinned in-test with provenance comments).

## Stable Core Impact

Touches `KDBXParser.swift`, `KDBXXMLSerializer.swift`, `KDBXCrypto.swift` (slice 01) and `KDBXParser.swift`, `KDBXWriter.swift` (slice 02) — intentional format/security work per `AGENTS.md`, with focused tests in each slice. The existing regression net for both slices is substantial and was built by the audit: `KDBXRoundTripTests`/`KDBXWriterTests` (shared tree assertions), `KDBXCompatibilityTests` (edit matrix + artifact emission), and the external gate's 22 protected-password checks, which exist precisely to catch a protected-stream slip externally.

## Slice plan

| # | Slice | File | Depends on |
|---|-------|------|------------|
| 01 | One ChaCha20 implementation + Salsa20 vectors | `01-chacha20-consolidation.md` | — |
| 02 | Preserve unknown KDBX4 inner-header fields | `02-unknown-inner-header-preservation.md` | — |

Two slices because the changes are independent, individually buildable/testable, and fail differently: 01 must produce byte-equivalent crypto (pure refactor + new vectors), 02 changes parse/write behavior and grows the compatibility matrix. Either can land first.

## Cross-slice notes

- **Threading:** all touched code already runs off the main thread (repo rule); neither slice changes that.
- **Security:** no new secret exposure; slice 01 touches the code paths that decrypt/encrypt protected values but must be behavior-identical (the point of the slice); slice 02 handles only non-secret header bytes that were already stored in plaintext-equivalent form inside the encrypted payload.
- **Compatibility gate:** slice 02 grows the artifact set 21 → 22; the fail-closed expectation tables and `expectedArtifactIDs` bookkeeping in `KDBXCompatibilitySupport` must be extended, per the post-audit architecture.
- **CHANGELOG:** slice 01 defers (no user-visible change). Slice 02 owns the epic's entry under `## Unreleased`: `- KeeForge now preserves unknown KDBX4 inner-header fields when saving, protecting data written by future KeePass format extensions`.

## Out of scope

- Consolidating Salsa20 (only one implementation exists; this epic only adds vectors for it).
- Any KDBX3 write support (3.1 stays read-only), `Meta/MemoryProtection` modeling, and the other deferred audit items (KeePass2-authored fixture, hostile-input probes, large-DB perf floor).
- Improving the KDBX4 corruption/wrong-password diagnostic messages (separate small product change; see the audit report).
