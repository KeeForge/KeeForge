# Models Folder

This folder holds the data and logic that the rest of the app depends on. It is the most security-sensitive part of the repo.

## High-Risk Core

- `KDBXParser.swift` and `KDBXCrypto.swift` implement database decryption, KDF handling, XML extraction, HMAC checks, and decompression guards.
- `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, and `TOTPGenerator.swift` define the in-memory representation of secrets and time-based codes.
- Changes here should be small, test-backed, and motivated by a real bug, format update, or security requirement.

## Other Models Here

- `DatabaseReference.swift` is the persisted identifier for a known database, including bookmarks, nicknames, quick-launch state, and cloud metadata.
- `CloudSyncModels.swift` describes cloud provider files and sync metadata used by the database list and sync coordinator.
- `PasskeyCredential.swift` parses KeePassXC-style custom fields into passkey data used by the app and AutoFill extension.

## Notes For Agents

- Secrets should stay encrypted in memory until the exact point of use.
- Keep parsing and crypto work off the main actor.
- If a format or compatibility change is unclear, check `../../docs/README.md` and the related spec before changing code.
- Relevant unit tests usually live in `../../KeeForgeTests/KDBXParserTests.swift`, `../../KeeForgeTests/EncryptedValueTests.swift`, `../../KeeForgeTests/TOTPGeneratorTests.swift`, `../../KeeForgeTests/KeyFileProcessorTests.swift`, and `../../KeeForgeTests/PasskeyTests.swift`.
