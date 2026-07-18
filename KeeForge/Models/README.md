# Models Folder

This folder holds the data and logic that the rest of the app depends on. It is the most security-sensitive part of the repo.

## High-Risk Core

- `KDBXParser.swift`, `KDBXWriter.swift`, and `KDBXCrypto.swift` implement KDBX 4.x read/write, KDF handling, XML extraction, HMAC checks, payload framing, and decompression guards.
- `KDBXOuterCipher.swift` centralizes outer-cipher UUID recognition, IV sizing, diagnostics, and AES-256-CBC, ChaCha20, and Twofish-256-CBC dispatch. The Twofish primitive lives in the locally vendored `Vendor/KeeForgeTwofish` package and is shared with AutoFill.
- `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, and `TOTPGenerator.swift` define the in-memory representation of secrets and time-based codes.
- `DatabaseDraft.swift` and `EntryEdit.swift` stage in-memory entry/group creates, updates, and deletes while preserving recycle-bin behavior, protected fields, and unknown XML for later save.
- Changes here should be small, test-backed, and motivated by a real bug, format update, or security requirement.

## Other Models Here

- `DatabaseReference.swift` is the persisted identifier for a known database, including bookmarks, nicknames, quick-launch state, read-only and edit-acknowledgment flags, and cloud metadata.
- `CloudSyncModels.swift` describes cloud provider files and sync metadata used by the database list and sync coordinator, including provider-specific optimistic-concurrency tokens such as Dropbox `rev` and OneDrive eTag/cTag values.
- `PasskeyCredential.swift` parses KeePassXC-style custom fields into passkey data used by the app and AutoFill extension.
- `KDBXFileSummary.swift` is a credential-free summary of a KDBX file's plaintext outer header (format version, cipher, compression, KDF settings) for display in Database Details; it reuses the parser's header routines read-only and accepts a bounded file prefix.
- `Attachment.swift` defines `KPAttachment` (name + pool ref, structurally parsed from `<Entry>/<Binary>`) and `BinaryPool`, which lazily decodes `Header.innerHeaderBinaryFields` (stripping the leading protection-flag byte) on subscript access by ref. Read-only in Phase 1: the writer only ever re-emits the inner-header binary pool verbatim: no ref renumbering, no new pool entries. Dangling refs (no pool entry at that index) are tolerated and resolve to `nil` rather than failing the parse.

## Notes For Agents

- Secrets should stay encrypted in memory until the exact point of use.
- Keep parsing and crypto work off the main actor.
- If a format or compatibility change is unclear, check `../../docs/README.md` and the related spec before changing code.
- Twofish uses strict PKCS#7 validation. Do not add permissive padding recovery without a sanitized interoperability fixture that proves it is required.
- Relevant unit tests usually live in `../../KeeForgeTests/KDBXParserTests.swift`, `../../KeeForgeTests/KDBXWriterTests.swift`, `../../KeeForgeTests/KDBXRoundTripTests.swift`, `../../KeeForgeTests/DatabaseDraftTests.swift`, `../../KeeForgeTests/EncryptedValueTests.swift`, `../../KeeForgeTests/TOTPGeneratorTests.swift`, `../../KeeForgeTests/KeyFileProcessorTests.swift`, `../../KeeForgeTests/PasskeyTests.swift`, and `../../KeeForgeTests/AttachmentTests.swift`.
