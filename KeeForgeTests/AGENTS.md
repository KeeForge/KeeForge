# KeeForgeTests

**Scope:** every unit test for the app, the AutoFill coordinator, and the KDBX core, compiled into both `KeeForgeTests` (iOS) and `KeeForgeMacTests` (macOS). Shared fakes and helpers are in `Support/` ([Support/AGENTS.md](Support/AGENTS.md)); bundled databases are described in [../TestFixtures/README.md](../TestFixtures/README.md).

## Picking a slice

Prefer a unit test here over a UI test unless the behavior only exists as UI. Run the class for the type you changed, on the platform you changed; the commands are in the root `AGENTS.md`.

- `-only-testing:` takes a class name, not a file name. `<Type>Tests.swift` declares `<Type>Tests` except where "Where to look" says otherwise.
- A change to shared source runs its class under both `KeeForgeTests/` and `KeeForgeMacTests/`. A suite wrapped in `#if os(macOS)` exists only under `KeeForgeMacTests/`.
- A change to format or save behavior also needs `KDBXCompatibilityTests`, and before a release the external gate in [../ci_scripts/AGENTS.md](../ci_scripts/AGENTS.md).

## What the suite covers

- **Parser, writer, crypto:** `KDBXParserTests` (decrypt, integrity rejection, foreign-authored cipher fixtures, Argon2 and Salsa20 known answers), `KDBXWriterTests` (container, header, HMAC, cipher, KDF), `KDBXRoundTripTests` (XML serializer and opaque-XML preservation), `KDFExecutionPolicyTests` (app versus AutoFill resource budgets), `ChaCha20Tests`, `TwofishTests`, `ChallengeResponseKeyTests`, `EncryptedValueTests`.
- Recycle Bin recovery: `DatabaseDraftTests` covers format references and boundary refusals; `DatabaseViewModelTests` covers save/reopen, destination visibility, nested recovery, read-only/stale requests, cancellation, and failed-write retry. Restore artifacts are in `KDBXCompatibilityTests`.
- Custom-icon management: `CustomIconXMLTests` pins surgical XML edits; `DatabaseDraftTests` covers entry/group/history fallback; `DatabaseViewModelTests` covers session guards and save/reopen; `KDBXMergerTests` covers icon tombstones and imported names. Rename/delete artifacts live in `KDBXCompatibilityTests`.
- **Edits and compatibility:** `DatabaseDraftTests` (in-memory edit semantics), `KDBXCompatibilityTests` (every supported edit written, reparsed, and handed to KeePassXC by the external gate).
- **Merge:** `KDBXMergerTests` (synthetic scenarios pinning the specified behavior, including recovery references following location independently of content), `KDBXMergerOracleTests` (the same engine compared with `keepassxc-cli merge` output under `../TestFixtures/Merge/`). The compatibility merge artifact also preserves remote recycling references through write/reopen.
- **Persistence and save paths:** `LocalDatabaseSaverTests`, `CloudDatabaseSaverTests`, `DatabaseListStoreTests`, `SharedVaultStoreTests`, `PendingUploadQueueTests`, `PendingUploadDrainerTests`, `PendingUploadRecoveryTests`, `KeychainServiceTests`, `AppGroupGuardrailTests`.
- **Cloud:** `CloudSyncCoordinatorTests` (open-time sync resolution and the cache swap), `DatabaseViewModelCloudSyncTests` (Sync Now in a session), one `<Provider>CloudProviderTests` per provider, `WebDAVClientTests`, `FTPListingParserTests`.
- **Session and workflow:** `DatabaseViewModelTests`, `AutoLockTests`, `HardwareKeyUnlockTests`, `DatabaseEditorCoordinatorTests`, `AppRoutingCoordinatorTests`.
- **AutoFill and passkeys:** `CredentialProviderCoordinatorTests` and its `CredentialProvider*Tests` siblings (save, registration, picker creation), `CredentialMatcherTests`, `CredentialIdentityStoreManagerTests`, `AutoFillMemoryLimitTests`, `PasskeyCredentialTests`, `PasskeyCryptoTests`.
- **Localization and bundle:** `LocalizationTests` (translation completeness and format-specifier parity for every shipped locale), `URLSchemeFormatTests` (declared URL schemes are legal after build-setting substitution).
- **macOS only:** `MacBiometricAutoUnlockTests`, `MacLockMonitorTests`, `MacWindowCloseGuardTests`, `MacQuickSearchViewModelTests`, `MacQuickAccessControllerTests`, `MacUnlockPasswordFieldTests`, `MacTransitionNoticeServiceTests`, `CredentialProviderShellMacTests`, and the SSH agent's `SSHAgentKeyTests`, `SSHAgentRequestHandlerTests`, `MacSSHAgentControllerTests`.

## Invariants

### Two targets, one folder

- `KeeForgeMacTests` compiles this folder, so every test costs both platforms. Keep tests platform-neutral; wrap a macOS-only suite or case in `#if os(macOS)` (and an iOS-only one in `#if os(iOS)`).
- `DropboxCloudProviderTests.swift` and `OneDriveCloudProviderTests.swift` are excluded from `KeeForgeMacTests` in `project.yml`: they import SwiftyDropbox and MSAL, which the Mac app does not link. Add any new suite that imports a cloud SDK to that list. The Mac side is carried by `CloudProviderRegistryTests` and `URLSchemeFormatTests`.
- `AutoFillStoreInspectorGroupingTests` compiles only under `DEBUG`, `SoftwareUpdateServiceTests` only under `KEEFORGE_DIRECT_DOWNLOAD` (the direct-download Mac build).
- A new bundled fixture is added to the `UnitTestFixtures` template in `project.yml`, which both targets use.

### Isolation from real user data

- `PendingLocalSaveTests` covers the Mac AutoFill write-back, conflict, merge, retained backup, and rekey paths. Run it with the saver, registration, and compatibility suites when this flow changes.

- Both targets are hosted by the real app. `AppGroupContainer.isRedirectedForTesting` sends App Group storage to a temporary container; without it a Mac run's `DatabaseListStore.clearAll()` deletes the developer's own database list and backups. `AppGroupIsolationTests` is the gate; never bypass the redirect.
- Tests that scan Documents set `DatabaseListStore.documentsDirectoryOverride`; never touch the real directory.
- `MacSSHAgentControllerTests` gives the controller a `UserDefaults` suite and a `NotificationCenter` of its own and a socket in a temporary directory. Never point it at `UserDefaults.standard`, which in the hosted Mac app holds the developer's real agent settings. Its OpenSSH round trip (`ssh-add`, `ssh-keygen`) skips in a sandboxed test host.
- `LocalDatabaseSaverTests` saves attachments at the reader's size limit and holds several hundred megabytes. Do not add tests of that size elsewhere.
- Inject the prompt, clipboard, clock, notification centers, and window effects. No unit test raises a system authentication prompt, writes the real pasteboard, shows a window, registers a global hot key, or locks the screen.
- Keychain-dependent cases (`CloudTokenStore`, `KeychainService`, WebDAV and FTP credentials) `XCTSkip` when the host cannot write the Keychain. A skip is not coverage.
- Suites that touch the AutoFill identity store follow the reset rule in [Support/AGENTS.md](Support/AGENTS.md).

### KDBX layering

- Each layer has one home: XML serializer in `KDBXRoundTripTests`, encrypted container in `KDBXWriterTests`, in-memory edits in `DatabaseDraftTests`, save-path safety (conflict, backup, verification, rekey, re-encryption) in the two saver suites and `CredentialProviderSaveTests` with representative edits only.
- The all-edit matrix lives only in `KDBXCompatibilityTests` and `Support/KDBXCompatibilitySupport.swift`. Do not copy it into writer, draft, or saver tests.
- Merge semantics belong to the two merger suites. The merge write path is the single compatibility scenario `merge-remote-divergence`.
- `KDBXMergerOracleTests` enumerates `../TestFixtures/Merge/manifest.json`. A scenario flagged `oracleMatchesSpec: false` must declare a `SpecOutcome` in the test, because `keepassxc-cli` does not apply `DeletedObjects`, adopt `Meta/RecycleBinUUID`, or update a moved entry's `LocationChanged`.
- `PendingUploadQueueTests` is the decode-compatibility gate for the pending-upload marker: marker JSON written by a shipped version must keep decoding.

### Compatibility matrix

- Every descriptor in `KDBXCompatibilitySupport.artifactDescriptors` is executed by exactly one `KDBXCompatibilityTests` method, which emits the bytes it just wrote for `../ci_scripts/run_kdbx_compatibility_gate.sh`. Nothing is re-run to produce a file; the Argon2 work would double.
- An emitting method creates an `ArtifactCollector`, runs scenarios through `collector.run(_:on:)` rather than `scenario.apply(to:)`, and ends with `try collector.emit()`. The collector throws on an undeclared or repeated artifact and on an empty emit.
- Each manifest fragment repeats the full expected artifact list, so a method that stops contributing fails the gate instead of shrinking coverage.
- To add a scenario: declare it in `artifactDescriptors`, run it in one method, and list its external expectations or add it to the matching `scenarioIDsWithout…Expectations` set. Lookups throw on an unlisted id and `test_externalExpectationTables_areExhaustiveOverEveryArtifactScenario` fails on stale ones.
- `smokeFixtures` feeds both the representative-fixture sweep and `artifactDescriptors`. A fixture with a dedicated deeper test goes in `smokeFixtureIDsWithDedicatedTests` so the sweep skips it; `kitchen-sink` is outside `smokeFixtures` and owned by its own method.
- `Scenario.apply` compares `binaryPoolDigest` (the whole inner-header pool, referenced or not) on every scenario, in addition to per-attachment hashes. Keep both: only the digest sees a dropped orphan, a reordered pool, or a flipped protection flag.
- `keepassxc-cli` cannot show group tags, opaque XML, `PublicCustomData`, or unknown inner-header fields. The gate proves those files still open with secrets and attachments intact; byte-faithful preservation is asserted in-process and must stay there.

### Localization and bundle tests

- `LocalizationTests` reads the four raw `.xcstrings` catalogs from the test bundle, never the source checkout: Xcode Cloud test machines have no checkout.
- A `postCompileScripts` phase on both test targets in `project.yml` copies them under disambiguated names. It is a script, not resource membership, because a compiled catalog drops the per-key `state` the test inspects.
- Renaming or moving a catalog means updating both copy scripts and `catalogSources` in the test. A new locale joins `shippedTranslationLocales`.
- `URLSchemeFormatTests` reads `Bundle.main`, the host app, so it sees substituted build settings. It is the only check before App Store Connect that a placeholder did not produce an illegal URL scheme.

## Where to look

Convention: `<Type>Tests.swift` declares `<Type>Tests` and covers `<Type>`. The exceptions:

- `PasskeyTests.swift`: `PasskeyCredentialTests`, `PasskeyCryptoTests`. There is no `PasskeyTests` class.
- `PasswordImportTests.swift`: `CSVReaderTests`, `ApplePasswordsCSVImporterTests`, `PasswordImportViewModelTests`.
- `SecretAccessGateTests.swift`: `SecretAccessGateTests` (the gate alone) and `SecretAccessSessionTests` (the grace period across a `DatabaseViewModel` session).
- `SettingsSummaryTests.swift`: `SettingsSummaryRowTests`, `AppSettingsSummaryTests`, `DatabaseSettingsSummaryTests`.
- `FTPListingParserTests.swift` also declares `FTPURLTests`; `FaviconServiceTests.swift` also declares `FaviconLoadModelTests`.
- `CloudFileBrowserViewModelTests` covers `CloudFileBrowserSession` and `CloudFolderBrowserViewModel`.
- `ModelLogicTests` holds pure model helpers with no suite of their own (icon tables, entry traversal, `OpaqueXMLNodes`, `KeeOTPSource` rewriting).

Designated gates:

- `AutoFillExtension/CredentialProviderCoordinator.swift`: `CredentialProviderCoordinatorTests`, on both platforms. It pins `cleanup()` on every completion path. The Mac shell's window-close and alert paths are `CredentialProviderShellMacTests`.
- `DatabaseViewModel` is split by concern: `DatabaseViewModelTests`, `DatabaseViewModelCloudSyncTests`, `AutoLockTests`, `HardwareKeyUnlockTests`, `SecretAccessSessionTests`, `SortOrderTests`. The vault half of macOS window close is an `#if os(macOS)` section of `DatabaseViewModelTests`.
- Rekey and re-encryption: the write is in the saver suites, the session guards in `DatabaseViewModelTests`.
- Editor completion across a save conflict: `EntryEditCompletionGateTests` is the only non-UI coverage. Editor save and reopen against the real saver is in `KDBXCompatibilityTests`.
- Argon2 and Salsa20 known-answer vectors are in `KDBXParserTests`, not a cipher suite.
- Not unit-testable here: the live `FTPNetworkStream` (needs a server), live StoreKit purchases, and typed key events in an inactive Mac app (covered in `KeeForgeMacUITests`).

## See also

- [Support/AGENTS.md](Support/AGENTS.md), [../TestFixtures/README.md](../TestFixtures/README.md)
- [../ci_scripts/AGENTS.md](../ci_scripts/AGENTS.md): the external KDBX compatibility gate
- [../AGENTS.md](../AGENTS.md): "macOS Test Strategy", including what Mac work has to test
- [../KeeForgeUITests/AGENTS.md](../KeeForgeUITests/AGENTS.md), [../KeeForgeMacUITests/AGENTS.md](../KeeForgeMacUITests/AGENTS.md)
