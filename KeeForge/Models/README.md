# Models Folder

This folder holds the data and logic that the rest of the app depends on. It is the most security-sensitive part of the repo.

## High-Risk Core

- `KDBXParser.swift`, `KDBXWriter.swift`, and `KDBXCrypto.swift` implement KDBX 4.x read/write, KDF handling, XML extraction, HMAC checks, payload framing, and decompression guards.
- `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, and `TOTPGenerator.swift` define the in-memory representation of secrets and time-based codes.
- `DatabaseDraft.swift` and `EntryEdit.swift` stage in-memory creates, updates, and deletes while preserving recycle-bin behavior, protected fields, and unknown XML for later save.
- Changes here should be small, test-backed, and motivated by a real bug, format update, or security requirement.

## Other Models Here

- `DatabaseReference.swift` is the persisted identifier for a known database, including bookmarks, nicknames, quick-launch state, read-only and edit-acknowledgment flags, and cloud metadata.
- `CloudSyncModels.swift` describes cloud provider files and sync metadata used by the database list and sync coordinator, including provider-specific optimistic-concurrency tokens such as Dropbox `rev` and OneDrive eTag/cTag values.
- `PasskeyCredential.swift` parses KeePassXC-style custom fields into passkey data used by the app and AutoFill extension.

## Notes For Agents

- Secrets should stay encrypted in memory until the exact point of use.
- Keep parsing and crypto work off the main actor.
- If a format or compatibility change is unclear, check `../../docs/README.md` and the related spec before changing code.
- Relevant unit tests usually live in `../../KeeForgeTests/KDBXParserTests.swift`, `../../KeeForgeTests/KDBXWriterTests.swift`, `../../KeeForgeTests/KDBXRoundTripTests.swift`, `../../KeeForgeTests/DatabaseDraftTests.swift`, `../../KeeForgeTests/EncryptedValueTests.swift`, `../../KeeForgeTests/TOTPGeneratorTests.swift`, `../../KeeForgeTests/KeyFileProcessorTests.swift`, and `../../KeeForgeTests/PasskeyTests.swift`.
