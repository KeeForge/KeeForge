# KeeForge Unit Tests

Use this folder to find the smallest test slice that proves a change. Prefer unit tests over UI tests unless the behavior is truly UI-driven.

## Running Tests

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

- Always use `-only-testing:`.
- Run only the classes touched by the change.
- If source files move between targets, regenerate the project with `xcodegen generate`.

## File Map

- Parser, writer, compatibility, and secret handling: `KDBXParserTests.swift`, `KDBXWriterTests.swift`, `KDBXRoundTripTests.swift`, `KDBXCompatibilityTests.swift`, `KDBXCompatibilityArtifactTests.swift`, `EncryptedValueTests.swift`, `TOTPGeneratorTests.swift`, `KeyFileProcessorTests.swift`, `VerifyKeyfileTests.swift`.
- Drafts, view models, and app state: `DatabaseDraftTests.swift`, `DatabaseViewModelTests.swift`, `DatabaseListViewModelTests.swift`, `EntryEditViewModelTests.swift`, `TOTPViewModelTests.swift`, `AutoLockTests.swift`, `SortOrderTests.swift`.
- Persistence, save pipeline, and shared storage: `DatabaseListStoreTests.swift`, `LocalDatabaseSaverTests.swift`, `CloudDatabaseSaverTests.swift`, `PendingUploadQueueTests.swift`, `PendingUploadDrainerTests.swift`, `DatabaseReferenceTests.swift`, `SharedVaultStoreTests.swift`, `DatabaseReferenceMigrationTests.swift`, `SettingsServiceTests.swift`, `SyncedFolderDetectorTests.swift`.
- Cloud and multi-database support: `CloudSyncModelsTests.swift`, `CloudProviderTests.swift`, `DropboxCloudProviderTests.swift`, `CloudProviderRegistryTests.swift`, `CloudAccountStoreTests.swift`, `CloudTokenStoreTests.swift`, `CloudFileBrowserViewModelTests.swift`. `DropboxCloudProviderTests.swift` covers Dropbox-specific OAuth scope behavior; OneDrive-specific registry/model coverage lives in the shared cloud tests.
- WebDAV sync (Slice 1): `WebDAVClientTests.swift` covers the PROPFIND multistatus parser fixtures (Nextcloud/sabre + `oc:`/`nc:` props, Apache mod_dav, propstat-404, folder/file discrimination, percent-encoded/unicode/absolute hrefs, self-entry skip, Depth 0 `includeSelf`), request construction (Basic auth, Depth headers, PUT conditionals, propfind body), response header extraction, and the HTTP/URLError mapping tables (incl. TLS/ATS → secure-connection, not offline). `WebDAVCloudProviderTests.swift` covers URL normalization + accountId derivation, fileId↔URL round-trip, rev/If-Match semantics, and stub-transport provider behaviors (getMetadata HEAD + 405→PROPFIND fallback, upload If-Match/412-conflict/HEAD-followup, createFile If-None-Match, listFiles filter/sort, notAuthenticated, connect probe/persist). Credential-dependent tests seed `CloudTokenStore` and `XCTSkip` when Keychain is unavailable.
- AutoFill and passkeys: `CredentialProviderSaveTests.swift`, `CredentialMatcherTests.swift`, `CredentialIdentityStoreManagerTests.swift`, `PasskeyTests.swift`, `PasskeyDisplayTests.swift`.
- Miscellaneous services: `FaviconServiceTests.swift`, `PasswordGeneratorTests.swift`, `ReviewPromptServiceTests.swift`, `ModelLogicTests.swift`, `KeychainMigrationTests.swift`.

## Test Helpers

- `TestDatabaseSupport.swift` builds fixture URLs, supports fixture subdirectories, and creates bookmark-backed `DatabaseReference` values for tests.
- `KDBXCompatibilitySupport.swift` is the shared compatibility harness. Keep the all-edit compatibility matrix there and in `KDBXCompatibilityTests.swift`; do not duplicate it in writer, draft, or saver tests.
- Shared databases and key files are documented in `../TestFixtures/README.md`.

## KDBX Compatibility Story

- `KDBXRoundTripTests.swift` is for parser/XML serializer regressions only.
- `KDBXWriterTests.swift` is for encrypted container, header, HMAC, cipher, KDF, and protected-value regressions only.
- `DatabaseDraftTests.swift` is for in-memory edit semantics only.
- `LocalDatabaseSaverTests.swift`, `CloudDatabaseSaverTests.swift`, and `CredentialProviderSaveTests.swift` are save-path safety tests with representative smoke edits.
- `KDBXCompatibilityTests.swift` is the authoritative end-to-end compatibility matrix for every supported edit type and rich KDBX fixture shape.
- `KDBXCompatibilityArtifactTests.swift` emits artifacts consumed by `../ci_scripts/run_kdbx_compatibility_gate.sh`, which validates generated files with `keepassxc-cli`.
