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

- Parser, writer, and secret handling: `KDBXParserTests.swift`, `KDBXWriterTests.swift`, `KDBXRoundTripTests.swift`, `EncryptedValueTests.swift`, `TOTPGeneratorTests.swift`, `KeyFileProcessorTests.swift`, `VerifyKeyfileTests.swift`.
- Drafts, view models, and app state: `DatabaseDraftTests.swift`, `DatabaseViewModelTests.swift`, `DatabaseListViewModelTests.swift`, `TOTPViewModelTests.swift`, `AutoLockTests.swift`, `SortOrderTests.swift`.
- Persistence, save pipeline, and shared storage: `DatabaseListStoreTests.swift`, `LocalDatabaseSaverTests.swift`, `CloudDatabaseSaverTests.swift`, `SyncedFolderDetectorTests.swift`, `DatabaseReferenceTests.swift`, `SharedVaultStoreTests.swift`, `DatabaseReferenceMigrationTests.swift`, `SettingsServiceTests.swift`.
- Cloud and multi-database support: `CloudSyncModelsTests.swift`, `CloudProviderTests.swift`, `DropboxCloudProviderTests.swift`, `CloudProviderRegistryTests.swift`, `CloudAccountStoreTests.swift`, `CloudTokenStoreTests.swift`, `CloudFileBrowserViewModelTests.swift`.
- AutoFill and passkeys: `CredentialMatcherTests.swift`, `CredentialIdentityStoreManagerTests.swift`, `PasskeyTests.swift`, `PasskeyDisplayTests.swift`.
- Miscellaneous services: `FaviconServiceTests.swift`, `ReviewPromptServiceTests.swift`, `ModelLogicTests.swift`, `KeychainMigrationTests.swift`.

## Test Helpers

- `TestDatabaseSupport.swift` builds fixture URLs, supports fixture subdirectories, and creates bookmark-backed `DatabaseReference` values for tests.
- Shared databases and key files are documented in `../TestFixtures/README.md`.
