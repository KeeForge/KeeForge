# AutoFillExtension

**Scope:** the credential-provider extensions `KeeForgeAutoFill` (iOS) and `KeeForgeMacAutoFill` (macOS): password, passkey, and one-time-code fulfilment through `AuthenticationServices`, plus save-password and picker-created entries on iOS. Matching, identity publishing, and the save path are shared services (`../KeeForge/Services/AutoFill/AGENTS.md`). This process has a small memory budget, no network, and dies when the request completes.

## Ownership

- `CredentialProviderCoordinator` owns a request end to end: vault access, unlock, matching, passkey assertion, completion. It stays free of UIKit and AppKit and talks to the shell only through `CredentialProviderPresenting`.
- `CredentialProviderViewController` (iOS) and `CredentialProviderViewControllerMac` are thin shells with no matching or vault logic.
- Both extension targets compile this whole folder, each file gated by `#if os()`. `../project.yml` also compiles the coordinator into the `KeeForge` app target, and the coordinator, Mac shell, `AutoFillSearchView`, `AutoFillPasskeyCreatorView`, and `AutoFillMacChrome` into `KeeForgeMac`, so unit tests can drive them.
- The extensions share one allow-listed set of files from outside this folder; the two lists in `../project.yml` must stay byte-identical (rule in `../KeeForge/Services/AGENTS.md`).

## Invariants

### Request lifecycle

- `cleanup()` is the extension's only lock: it drops the session key, composite key, parsed vault, and pending request state. Every completion path (success, cancel, error-alert dismissal, silent-request failure, extension configuration) must go through the completion helpers (`finishRequest`) so it runs before the shell touches the extension context. A path that completes the context directly leaves a decrypted vault in memory.
- `CredentialProviderCoordinatorTests` pins a test per completion path and `CredentialProviderShellMacTests` the Mac shell's routing. This is the designated lifecycle regression gate, on iOS and macOS.
- The Mac shell also routes `NSAlert` dismissal and window close (`viewDidDisappear` calls `cancelActiveRequestIfNeeded()`) through the coordinator; window close has no iOS analogue.
- Mac `viewDidAppear` signals `presentationDidBecomeActive()` on a later main-loop turn, never synchronously: AppKit suppresses an `NSAlert.runModal()` started inside the window-ordering transaction, turning the unlock prompt into a silent cancel.
- Terminal completion happens exactly once. Request generations invalidate late unlock and save continuations, including creator callbacks from an earlier request; dismissing an internal iOS modal is not cancellation. A save already in progress may commit its bytes and refresh identities, but its obsolete result must not restore cleared vault state, show alerts, or complete a replacement request.
- Post-unlock UI goes through `presentWhenActive`, which defers while the shell is off screen, so a modal is never dropped.

### What may be filled

- An interactive list request is never answered with an automatic fill. The key icon (`prepareCredentialList`) means "let me choose", so `presentPasswordMatchesOrFinish` completes outright only for a record identifier it resolves; everything else, even a lone strict match, presents the picker. That includes a gone entry, a `.stale` target, and the passkey list falling back to passwords.
- Likewise `presentPasskeyList` offers a lone passkey and `presentOTCMatchesOrFinish` a lone code instead of asserting or generating. The by-identity routes (`completeInteractivePasskeyRequest`, `completeOTCRequestFromPending`) name the tapped credential and complete directly.
- Only the silent no-UI path turns a match into a credential on its own, and only via `strictMatchedEntries`. Pickers list the broader `matchedEntries`.
- Expired entries are excluded from proactive identities and automatic fulfilment; the picker lists them with a warning and requires a tap.
- `completeRequest(with:)` resolves `{REF:...}` in the filled username and password over `parsedRootGroup.allEntries` (the target may be password-less or in a non-searchable group). Picker rows, identities, and every write path never resolve.
- With `SettingsService.autoFillCopyTOTP` on, `completeRequest(with:)` copies the code before `cleanup()` drops the session key. A no-UI extension cannot reliably write the pasteboard, so the silent path escalates to `.userInteractionRequired` when the setting is on and the entry has a code.

### Memory and time

- `loadEntries` pre-flights each unlock with `AutoFillMemoryLimit.check`, which throws before Argon2 allocates (narrow rules in `../KeeForge/Services/AutoFill/AGENTS.md`). The error surfaces through `showErrorAndRetry`; the silent path escalates first.
- Every parse and save passes `KDFExecutionPolicy.autoFillExtension`: a static peak-memory ceiling for hostile KDF headers, set well above any real allowance so it never refuses a vault the runtime check or the app would open, plus the shared work and parallelism budgets. On macOS it is the only memory guard; `os_proc_available_memory` does not exist there.
- Avoid extra copies of decrypted payloads; large databases are the usual cause of a kill. A bookmarked local database is read with a 10 s bound (`readBookmarkedDatabase`); a stalled file provider falls back to the shared copy.

### Database and unlock

- A record identifier (QuickType tap, silent fill, passkey or code by identity) unlocks the database that owns it; identifier-less flows (manual search, save, passkey registration) use `DatabaseListStore.defaultAutoFillDatabase`. Disabled databases are treated as nonexistent, stale identities are removed on tap, and with none enabled the shells show `AutoFillNoEnabledDatabasesView`.
- iOS reads a bookmarked local database from its file, else the App Group copy. The copy is the only source for cloud databases (only the app syncs), Documents-resident files, and every database in the Mac extension (no bookmark entitlement; `../KeeForgeMac/SECURITY.md`).
- Biometrics are checked against the target database's own Keychain item, never the active database's. AutoFill always evaluates the biometric-only policy, so its prompt never offers Apple Watch, even on the Mac. A password unlock refreshes the shared item. Keychain rules: `../KeeForge/Services/Security/AGENTS.md`.
- A database with a YubiKey (`DatabaseReference.hardwareKey`) is refused with an explanation: YubiKit is not linked here and the stored key is only a pre-key.
- With two or more enabled databases the picker offers a switcher (`CredentialProviderDatabaseSwitcherContext`). The previous vault stays until the new unlock succeeds, so cancelling falls back instead of ending the request.

### Saving

- The extension never uploads. A save goes through `AutoFillSaveCoordinator.saveNewEntry` into `LocalDatabaseSaver` and, for a cloud database, leaves a pending-upload marker before success is returned; the app drains it. Marker rules: `../KeeForge/Services/Cloud/AGENTS.md`; save paths: `../KeeForge/Services/AGENTS.md`.
- Picker-initiated creation (`makeEntryCreationAction`) exists only on iOS, against a writable non-KDBX-3.1 database, for a request with a service identifier; passkey and code pickers stay selection-only. It completes with an `ASPasswordCredential` from the confirmed draft, while save-password completes with `completeSavePasswordRequest`.
- Passkey registration (iOS and macOS) mirrors save-password, then cancels with `.matchedExcludedCredential` when an excluded descriptor matches a stored passkey. The database is saved first and `completeRegistrationRequest` runs only after the save succeeds, so the relying party never receives a credential that was not persisted. Every request still ends in a completion or cancel; an unsupported or malformed one cancels with `.failed`.

### What the extension may touch

- No network. The Mac extension's sandbox grants no network entitlement, `PrivacyInfo.xcprivacy` declares no collection, and `FaviconService` is compiled in but never called. Revisit the manifest's required-reason entries when the allow-list changes.
- Clipboard: only the iOS branch of `ClipboardService` is called from here (verification-code copy; the system pasteboard expiration outlives the process). The macOS branch clears with an in-process timer that dies with the extension, so the coordinator gates the copy on `#if os(iOS)`.
- App Group writes go only through the services in `../KeeForge/Services/Persistence/AGENTS.md`.
- `com.keevault.sharedkeychain` must stay first in both extension entitlements files (rule in `../KeeForge/Services/Security/AGENTS.md`). `KeeForgeMacAutoFill` mirrors the iOS extension's single group and enables Hardened Runtime with zero `com.apple.security.cs.*` exceptions.

## macOS

- `.toolbar` and `.searchable` do not render in the macOS AutoFill panel: SwiftUI routes them to the window's `NSToolbar`, and the system credential-provider window has none. Every view the Mac shell hosts must draw its own title, search, switcher, and exit inside the view (`AutoFillMacChrome.swift`). A toolbar-only Cancel compiles, passes every unit test, and ships a panel the user cannot leave, blocking the calling app.
- The Mac extension fills passwords, passkeys, and one-time codes (`ProvidesPasswords`, `ProvidesPasskeys`, `ProvidesOneTimeCodes` in `InfoMac.plist`; codes need macOS 15, the deployment floor) and saves passkey registrations.
- `ASSavePasswordRequest`, `ASGeneratePasswordsRequest`, `ASGeneratedPassword`, `completeSavePasswordRequest`, and `completeGeneratePasswordRequest` are `API_UNAVAILABLE(macos)` (rechecked against the 27.0 SDK headers). The coordinator's save and generate surface is `#if os(iOS)`, the Mac shell's equivalents are unreachable stubs, and `InfoMac.plist` omits the `Supports*PasswordCredentials*` keys.
- Identity store: `ASCredentialIdentityStoreState.supportsIncrementalUpdates` is false on macOS (verified against a real enabled provider). `saveCredentialIdentities` then means "pass all identities", `removeCredentialIdentities` is unsupported, and enumeration returns nothing or private objects with no readable `recordIdentifier`. The system store therefore holds one database's identities, the most recently unlocked AutoFill-enabled one, and Safari suggests from it alone. A tapped suggestion still unlocks its owning database; the switcher and `defaultAutoFillDatabase` keep the others reachable. `CredentialIdentityStoreManager` gates on the runtime flag, not `#if os(macOS)`.

## Tests

In `../KeeForgeTests/` (run on iOS, and on macOS through `KeeForgeMacTests`, which compiles that folder):

- `AutoFillMemoryLimitTests`, `KDFExecutionPolicyTests`: the memory and time guards.
- `CredentialProviderCoordinatorTests` first for any coordinator change, then `CredentialProviderSaveTests`, `CredentialProviderPickerCreationTests`, `CredentialProviderRegistrationTests`.
- `CredentialProviderShellMacTests` (`KeeForgeMacTests` only): Mac shell routing and cleanup.
- `CredentialIdentityStoreManagerTests`, `CredentialMatcherTests`, `PasskeyCryptoTests` (in `PasskeyTests.swift`), `SharedVaultStoreTests`.

## See also

- `../KeeForge/Services/AGENTS.md`: save paths, pending uploads, the shared-source allow-list rule
- `../KeeForge/Services/AutoFill/AGENTS.md`, `../KeeForge/Services/Security/AGENTS.md`
- `../KeeForge/AGENTS.md`: KDBX compatibility; `../KeeForgeMac/SECURITY.md`, `../docs/threat-model.md`
