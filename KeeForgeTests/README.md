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

- Parser, writer, compatibility, and secret handling: `KDBXParserTests.swift`, `KDBXWriterTests.swift`, `KDBXRoundTripTests.swift`, `KDBXCompatibilityTests.swift`, `KDBXCompatibilityArtifactTests.swift`, `EncryptedValueTests.swift`, `TOTPGeneratorTests.swift`, `KeyFileProcessorTests.swift`, `VerifyKeyfileTests.swift`, `KDBXFileSummaryTests.swift` (header-only metadata summary for Database Details, including prefix-only parsing), `DatabaseFileInfoLoaderTests.swift` (bookmark-resolved size/date/header loading for the details sheet).
- Twofish primitive and CBC/PKCS#7 coverage: `TwofishTests.swift`; parser/writer and cipher-preservation scenarios remain in the KDBX parser, writer, saver, and compatibility suites.
- Drafts, view models, and app state: `DatabaseDraftTests.swift`, `DatabaseViewModelTests.swift`, `DatabaseListViewModelTests.swift`, `EntryEditViewModelTests.swift`, `TOTPViewModelTests.swift`, `AutoLockTests.swift`, `SortOrderTests.swift`.
- Persistence, save pipeline, and shared storage: `DatabaseListStoreTests.swift`, `LocalDatabaseSaverTests.swift`, `CloudDatabaseSaverTests.swift`, `PendingUploadQueueTests.swift`, `PendingUploadDrainerTests.swift`, `DatabaseReferenceTests.swift`, `SharedVaultStoreTests.swift`, `DatabaseReferenceMigrationTests.swift`, `SettingsServiceTests.swift`, `SyncedFolderDetectorTests.swift`.
- Cloud and multi-database support: `CloudSyncModelsTests.swift`, `CloudProviderTests.swift`, `DropboxCloudProviderTests.swift`, `CloudProviderRegistryTests.swift`, `CloudAccountStoreTests.swift`, `CloudTokenStoreTests.swift`, `CloudFileBrowserViewModelTests.swift`. `DropboxCloudProviderTests.swift` covers Dropbox-specific OAuth scope behavior; OneDrive-specific registry/model coverage lives in the shared cloud tests.
- WebDAV sync (Slice 1): `WebDAVClientTests.swift` covers the PROPFIND multistatus parser fixtures (Nextcloud/sabre + `oc:`/`nc:` props, Apache mod_dav, propstat-404, folder/file discrimination, percent-encoded/unicode/absolute hrefs, self-entry skip, Depth 0 `includeSelf`), request construction (Basic auth, Depth headers, PUT conditionals, propfind body), response header extraction, and the HTTP/URLError mapping tables (incl. TLS/ATS → secure-connection, not offline). `WebDAVCloudProviderTests.swift` covers URL normalization + accountId derivation, fileId↔URL round-trip, rev/If-Match semantics, and stub-transport provider behaviors (getMetadata HEAD + 405→PROPFIND fallback, upload If-Match/412-conflict/HEAD-followup, createFile If-None-Match, listFiles filter/sort, notAuthenticated, connect probe/persist). Credential-dependent tests seed `CloudTokenStore` and `XCTSkip` when Keychain is unavailable.
- AutoFill and passkeys: `CredentialProviderSaveTests.swift`, `CredentialMatcherTests.swift`, `CredentialIdentityStoreManagerTests.swift`, `PasskeyTests.swift`, `PasskeyDisplayTests.swift`.
- Miscellaneous services: `FaviconServiceTests.swift`, `PasswordGeneratorTests.swift`, `ReviewPromptServiceTests.swift`, `AutoFillStatusServiceTests.swift`, `WhatsNewPresentationServiceTests.swift`, `ModelLogicTests.swift`, `KeychainMigrationTests.swift`. The What's New tests cover once-per-version persistence, versions without feature content, UI-test suppression/opt-in, and iOS/macOS feature filtering.
- Localization: `LocalizationTests.swift` reads the four raw `.xcstrings` catalog sources from the **test bundle** (not the source checkout) and gates German completeness: every non-empty key has a translated `de` `stringUnit`, `%`-format-specifier multisets match between `en` and `de` (positional specifiers normalized), the keys shared between the app and AutoFill `Localizable.xcstrings` have identical `de` values, and `Bundle.main.localizations` advertises `de`. The catalogs are copied into the built `.xctest` bundle verbatim (as `KeeForge_Localizable.xcstrings`, `KeeForge_InfoPlist.xcstrings`, `AutoFillExtension_Localizable.xcstrings`, `AutoFillExtension_InfoPlist.xcstrings`) by the `postCompileScripts` phase on the `KeeForgeTests` target in `project.yml` — a script, not a resource membership, so Xcode does not compile them (a compiled catalog drops the per-key `state` field the test inspects). The script writes to `$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH` (the host-app-embedded bundle that actually runs), not `$BUILT_PRODUCTS_DIR`. This makes the test correct on Xcode Cloud, whose `test-without-building` machines lack the repository checkout; reading source files by path there fails. If you rename or move these catalogs, update both the copy script's input paths and `catalogSources` in the test.
- macOS port (slice 01): `SecurityScopedBookmarkManagerTests.swift` proves `.withSecurityScope` bookmark creation/resolution on macOS (plus the plain-bookmark fallback) and unchanged iOS behavior; `AppGroupGuardrailTests.swift` pins `SharedVaultStore`'s group-container write surface to encrypted KDBX payloads, bookmark blobs, and filename metadata only (the container is user-world-readable on macOS 14).
- macOS port (slice 03): `CloudProviderDesktopAuthTests.swift` (`#if os(macOS)`, runs in `KeeForgeMacTests` only) asserts the Dropbox/OneDrive mac auth paths stop at the `invalidConfiguration` gate instead of the slice-01 "unavailable" stub, that MSAL webview parameters derive from the anchor window's `contentViewController`, that the mac bundle registers the `db-*`/`msauth.*` redirect schemes, and that OneDrive declines redirect URLs on macOS (MSAL intercepts them internally). Auth-with-real-keys is manual-only; the authenticate tests `XCTSkip` when real keys are configured.
- macOS unlock keyboard handling (`MacUnlockPasswordField`) is covered by UI tests only (`MacSmokeUITests.testEscapeInUnlockReturnsToDatabaseList` / `testUnlockSucceedsWithCorrectPassword`): unit-level coverage was tried and removed — driving a real field editor requires first-responder status the shared unit-test host cannot reliably obtain (the app is never frontmost), which made the tests fail deterministically in exactly the environments they were meant to protect.

## macOS Test Target

This folder is compiled into both `KeeForgeTests` (iOS) and `KeeForgeMacTests` (macOS, hosted by `KeeForgeMac.app`). Run the Mac suite with:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' -only-testing:KeeForgeMacTests -quiet
```

Keep new tests platform-neutral where possible; gate genuinely platform-specific expectations with `#if os()` and a comment naming the reason.

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
- The compatibility matrix runs the full edit set for both AES and synthetic Twofish databases, and the artifact gate asks `keepassxc-cli` to open KeeForge-produced Twofish output.
- `KDBXCompatibilityArtifactTests.swift` emits artifacts consumed by `../ci_scripts/run_kdbx_compatibility_gate.sh`, which validates generated files with `keepassxc-cli`.
