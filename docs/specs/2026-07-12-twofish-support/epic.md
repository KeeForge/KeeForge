# Epic: Twofish KDBX Support

## Summary

Add standards-compatible Twofish-256-CBC support to KeeForge so the app and AutoFill extension can open Twofish-encrypted KDBX 3.1 and 4.x databases, and can edit and save KDBX 4.x databases without silently changing their outer cipher. KDBX 3.1 remains read-only, matching KeeForge's existing legacy-format policy.

## Clarified requirements

- **Q: Which format operations are supported?**
  **A:** Full KDBX 4.x read/write cipher preservation across the main app, AutoFill, local save, cloud save, and conflict-copy paths. KDBX 3.1 Twofish is read-only; its writer path remains rejected.
- **Q: Can users create or convert a database to Twofish?**
  **A:** No. Do not add a creation selector, database-settings control, migration prompt, or automatic conversion. Fresh databases continue to use AES-256-CBC.
- **Q: Which implementation is approved?**
  **A:** Vendor the pristine Niels Ferguson Twofish C implementation, version 0.3, in a local Swift package at `Vendor/KeeForgeTwofish`. Keep the original copyright/license text, add a KeeForge-owned Swift CBC/PKCS#7 layer, and do not copy competitor wrappers.
- **Q: How strict is decryption?**
  **A:** Require a 32-byte KDBX key, 16-byte IV, non-empty block-aligned ciphertext, and valid PKCS#7 padding. Do not add a permissive padding fallback unless a future sanitized real-world fixture proves it is necessary.
- **Q: What are the security and concurrency requirements?**
  **A:** Initialize Ferguson's global tables exactly once in a thread-safe way, keep key schedules operation-local, clear mutable schedules and temporary buffers on every exit path, emit no key/plaintext/ciphertext logs, and keep all database crypto off the main actor.
- **Q: Is streaming part of this work?**
  **A:** No. Preserve the current whole-`Data` KDBX pipeline and prove acceptable behavior with a fixture containing an attachment larger than 1 MiB.
- **Q: Is rollout gated?**
  **A:** No feature flag. The supported cipher UUID activates the path; unknown UUIDs retain the existing unsupported-format behavior.

## Competitor and reference findings

- [KeePassium](https://github.com/keepassium/KeePassium#features) advertises read/write KDBX 3 and 4 support with Twofish and credits the Niels Ferguson implementation. Its useful precedent is one shared crypto implementation across the app and AutoFill, not its GPL-licensed integration code.
- [Strongbox](https://github.com/strongbox-password-safe/Strongbox/blob/26ecccf4633921a20dd354a1548a740fbcb07ab7/README.md#L1-L6) supports Twofish for KDBX 3.1 and 4, preserves the parsed cipher UUID on save, and exposes deliberate cipher conversion. Its registry maps UUID `AD68F29F-576F-4BB9-A36A-D47AF965346C` to a Twofish implementation ([source](https://github.com/strongbox-password-safe/Strongbox/blob/26ecccf4633921a20dd354a1548a740fbcb07ab7/model/keepass/KeePassCiphers.m#L220-L249)). KeeForge adopts preservation but intentionally omits conversion UI.
- [KeePassXC](https://github.com/keepassxreboot/keepassxc#features-list) supports KDBX 3/4 plus Twofish and is the external compatibility oracle used by KeeForge's artifact gate.
- The [official Twofish source page](https://www.schneier.com/academic/twofish/download/) identifies Ferguson's C library as free for all uses. The v0.3 source grants use and modification for any purpose provided its copyright message remains in source ([license text](https://sources.debian.org/src/twofish/0.3-5/twofish.c/)).
- Competitor code is reference-only: Strongbox is AGPL-3.0 and KeePassium is GPLv3. Only the separately licensed Ferguson source is vendored.

## Stable Core Impact *(KeeForge only)*

Touches `KDBXCrypto.swift`, `KDBXParser.swift`, and `KDBXWriter.swift`, all listed as stable core, because the reported database uses a valid standard KDBX outer cipher that the core currently rejects. `KDBX3Parser.swift` also needs format routing for read-only legacy support. Focused primitive vectors, parser/writer fixture tests, the full edit compatibility matrix, save-pipeline tests, and the external KeePassXC artifact gate are required before completion.

## Slice plan

| # | Slice | File | Depends on |
|---|-------|------|------------|
| 01 | Twofish crypto foundation | `01-twofish-crypto-foundation.md` | — |
| 02 | KDBX write and cipher routing | `02-kdbx-write-and-cipher-routing.md` | 01 |
| 03 | Open, save, and compatibility coverage | `03-open-save-and-compatibility.md` | 01, 02 |

The split follows security and layering boundaries. Slice 01 can validate the vendored primitive and strict CBC wrapper without changing supported KDBX behavior. Slice 02 wires that tested module into the stable parser/writer core and proves the three representative formats. Slice 03 expands the existing end-to-end compatibility and persistence gates across app, cloud, conflict, and AutoFill paths.

## Cross-slice notes

- **Cipher identity:** Twofish is the standard 16-byte UUID `AD68F29F-576F-4BB9-A36A-D47AF965346C`; display it as `Twofish-256-CBC` in diagnostics.
- **Public interfaces:** the local package exposes checked 16-byte block operations for official 128/192/256-bit vectors and a checked KDBX CBC API restricted to a 256-bit key and 16-byte IV. Core KDBX routing owns UUID-to-algorithm selection so parser, writer, IV sizing, and diagnostics cannot drift.
- **KDBX 4 integrity order:** verify the header HMAC and every payload-block HMAC before attempting Twofish decryption. Tampering must fail as HMAC corruption, not as padding or credentials.
- **KDBX 3 credentials:** because KDBX 3.1 lacks the KDBX 4 HMAC envelope, normalize strict-padding failure and stream-start mismatch to the existing invalid-credentials/open-failure path.
- **Preservation:** reuse the parsed KDBX 4 minor version, cipher UUID, KDF parameters, compression flag, protected-field stream, unknown outer header fields, inner-header binaries, protected values, attachments, and unknown XML. Generate fresh seed/IV material as the writer already requires.
- **Creation:** `DatabaseCreationService` continues to request AES-256-CBC. Supporting a parsed Twofish header must not change the fresh-header default.
- **Threading:** the package is `Sendable`-safe through immutable inputs and operation-local mutable state. Existing parser/writer callers remain responsible for running the whole operation off the main actor.
- **Logging:** tests may capture application logs, but neither the C shim, Swift wrapper, nor KDBX routing may log secrets or raw cryptographic buffers.
- **Rollout:** no migration, persisted setting, telemetry field, or feature flag.

## Overall acceptance

- The reported KDBX 4.0 profile—Twofish, Argon2d with 3 iterations, 16 MiB memory, parallelism 4, gzip, password-only—opens successfully.
- A KDBX 4.1 Twofish database using Argon2id, password plus key file, no compression, protected fields, attachments, and an unknown outer header opens, edits, saves, and reparses without changing those properties.
- A KDBX 3.1 Twofish/AES-KDF/Salsa20/gzip database opens read-only and all save entry points continue to reject it.
- Local, cloud, conflict-copy, and AutoFill saves preserve Twofish-encrypted KDBX 4 bytes as valid Twofish KDBX files; lock/session lifecycle remains unchanged.
- AES and ChaCha20 parser/writer coverage and AES fresh-database creation remain green.
- KeeForge-generated Twofish artifacts open in `keepassxc-cli`, including the rich edit matrix and attachment checks.

## Out of scope

- KDBX 3.1 writing or conversion to KDBX 4.
- A user-facing cipher chooser, database conversion workflow, or making Twofish the creation default.
- Permissive/nonstandard padding recovery.
- Streaming encryption/decryption or a broader crypto architecture rewrite.
- KDB/KeePass 1 and Password Safe formats.
- UI changes, accessibility identifiers, UI tests, or new network behavior.
