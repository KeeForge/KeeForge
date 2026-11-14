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
- Terminal completion happens exactly once. Picker actions are bound to the current request and presentation; starting a database switch or opening a creator invalidates the old picker. Shells check validity before dismissing picker content, and iOS checks again after dismissal. Request generations invalidate late unlock and save continuations; dismissing an internal iOS modal is not cancellation. A save already in progress may commit its bytes and refresh identities, but its obsolete result must not restore cleared vault state, show alerts, or complete a replacement request.
- Post-unlock UI goes through `presentWhenActive`, which defers while the shell is off screen, so a modal is never dropped.
- The unlock prompt names the database it opens (`presentUnlockPrompt(database:)`). On iOS it is `AutoFillUnlockView`, hosted like the picker; the shell dismisses it before handing the answer to the coordinator, which re-prompts only while nothing is presented. It offers no database switching before unlock, and its password field is secure-only: no reveal inside another app's request. macOS keeps its `NSAlert`.

### What may be filled

- An interactive list request is never answered with an automatic fill. The key icon (`prepareCredentialList`) means "let me choose", so `presentPasswordMatchesOrFinish` completes outright only for a record identifier it resolves; everything else, even a lone strict match, presents the picker. That includes a gone entry, a `.stale` target, and the passkey list falling back to passwords.
- Likewise `presentPasskeyList` offers a lone passkey and `presentOTCMatchesOrFinish` a lone code instead of asserting or generating. The by-identity routes (`completeInteractivePasskeyRequest`, `completeOTCRequestFromPending`) name the tapped credential and complete directly.
- Only the silent no-UI path turns a match into a credential on its own, and only via `strictMatchedEntries` (`SiteMatcher.strictMatches`). Password and code pickers use `interactiveMatches`: exact first-host matches, otherwise a separate possible-host section, with the complete corpus accessible through search or Show All Credentials. Rows show normalized hosts. Expanded searches replace the initial sections instead of repeating possible matches. Code pickers never offer URL addition.
- Expired entries are excluded from proactive identities and automatic fulfilment; the picker lists them with a warning and requires a tap.
- `completeRequest(with:)` resolves `{REF:...}` in the filled username and password over `parsedRootGroup.allEntries` (the target may be password-less or in a non-searchable group). Picker rows, identities, and every write path never resolve. Because a fill resolves, no value a website or relying party supplies may be saved with a reference in it: save-password refuses one in the username or password, and passkey registration refuses one in the user name.
- With `SettingsService.autoFillCopyTOTP` on, `completeRequest(with:)` copies the code before `cleanup()` drops the session key. A no-UI extension cannot reliably write the pasteboard, so the silent path escalates to `.userInteractionRequired` when the setting is on and the entry has a code.
- On iOS, the system text-insertion menu opens a manual TOTP picker without service identifiers; selection returns the generated code through the text-insertion completion and clears the session. Its request state, unlock, database switching and code generation live in the shared coordinator and are tested on both platforms; the system callback and completion API stay in the iOS shell. The Mac shell fails closed for this unavailable completion. An empty code list stays open so the user can switch to another enabled database or cancel. Successful insertion counts as a completed AutoFill; cancellation does not. It remains available when a field is not recognized as a code field.

### Memory and time

- `loadEntries` pre-flights each unlock with `AutoFillMemoryLimit.check`, which throws before Argon2 allocates (narrow rules in `../KeeForge/Services/AutoFill/AGENTS.md`). The error surfaces through `showErrorAndRetry`; the silent path escalates first.
- Every parse and save passes `KDFExecutionPolicy.autoFillExtension`: a static peak-memory ceiling for hostile KDF headers, set well above any real allowance so it never refuses a vault the runtime check or the app would open, plus the shared work and parallelism budgets. On macOS it is the only memory guard; `os_proc_available_memory` does not exist there.
- An express-unlock key opens a file without running the KDF, so `loadEntries` validates the header against `.autoFillExtension` on every unlock. A header over it opens for filling but is not writable (`kdfWriteRefusalMessage`): every save derives under that policy and would fail.
- Avoid extra copies of decrypted payloads; large databases are the usual cause of a kill. A bookmarked local database is read with a 10 s bound (`readBookmarkedDatabase`); a stalled file provider falls back to the shared copy.

### Database and unlock

- A record identifier (QuickType tap, silent fill, passkey or code by identity) unlocks the database that owns it; identifier-less flows (manual search, save, passkey registration) use `DatabaseListStore.defaultAutoFillDatabase`. Disabled databases are treated as nonexistent, stale identities are removed on tap (the whole store is cleared instead where it has no incremental updates or cannot be enumerated), and with none enabled the shells show `AutoFillNoEnabledDatabasesView`.
- iOS reads a bookmarked local database from its file, else the App Group copy. The copy is the only source for cloud databases (only the app syncs), Documents-resident files, and every database in the Mac extension (no bookmark entitlement; `../KeeForgeMac/SECURITY.md`).
- Biometrics are checked against the target database's own Keychain item, never the active database's. AutoFill always evaluates the biometric-only policy, so its prompt never offers Apple Watch, even on the Mac. A password unlock refreshes the shared item. Keychain rules: `../KeeForge/Services/Security/AGENTS.md`.
- Quick unlock reads the quick-unlock and express-unlock items in one `biometricQuickUnlockKeys` step with the context that released the first, and every unlock writes the opened version's express key back after the quick-unlock key (`QuickUnlockKeychain`, rules in `../KeeForge/Services/Security/AGENTS.md`). A cached key that does not open the file only costs the KDF; `AutoFillMemoryLimit` still pre-flights as if the KDF runs.
- `canUseBiometrics` first deletes a quick-unlock item whose master password is due (`QuickUnlockKeychain.expireIfDue`), and a biometric tap checks again before reading, falling back to the password prompt, since the interval can run out while the prompt is up. A password unlock restarts the interval; a quick unlock never extends it.
- A password unlock of a database with a remembered key file (`hasAssociatedKeyFile`) fails with a key-file error when the key file cannot be resolved or read; it never derives a password-only key, which would report a correct password as wrong.
- A database with a YubiKey (`DatabaseReference.hardwareKey`) is refused with an explanation, by password and by biometrics: YubiKit is not linked here and the stored key is only a pre-key. It never reads, uses, or stores an express key.
- With two or more enabled databases the picker offers a switcher (`CredentialProviderDatabaseSwitcherContext`). The previous vault stays until the new unlock succeeds, so cancelling falls back instead of ending the request.

### Saving

- On macOS, a passkey registration for a bookmarked local database saves to the shared encrypted copy and stores the resulting bytes in `PendingLocalSaveStore` before registration completes. The extension cannot write the bookmarked file. The app merges the pending save into that file after unlock; the creator must explain this delay. Cloud databases and KeeForge-only databases already save to their shared copy, while iOS can write its bookmarked file.

- The extension never uploads. A save goes through `AutoFillSaveCoordinator.saveNewEntry` into `LocalDatabaseSaver` and, for a cloud database, leaves a pending-upload marker before success is returned; the app drains it. Marker rules: `../KeeForge/Services/Cloud/AGENTS.md`; save paths: `../KeeForge/Services/AGENTS.md`.
- Picker actions that write the database share `canWriteActiveDatabase` (reference not read-only, file not KDBX 3.1, KDF within the extension's budget); save-password and passkey registration refuse with the same reason (`writeRefusalMessage`); without it the picker gets no write handler and hides the action. That covers the add-website action (`AutoFillURLAddition`) on both platforms and picker-initiated creation (`makeEntryCreationAction`), which exists only on iOS, for a request with a service identifier; passkey and code pickers stay selection-only. It completes with an `ASPasswordCredential` from the confirmed draft, while save-password completes with `completeSavePasswordRequest`.
- The add-website action is offered on every password-picker row (search, Show All Credentials, possible matches) whose entry does not already store the host. Its host comes only from the first web service identifier, reduced to scheme, host, and port, never from page content. The confirmation names that host beside the entry's saved URLs and adds a caution when it shares no registrable domain with any of them: a phishing page is the case it catches. Confirming appends the next free `KP2A_URL_<n>` and changes no other field. A draft error, save error, or SHA-512 conflict still fills the chosen entry as opened: the fill is what the user asked for.
- Passkey registration (iOS and macOS) mirrors save-password, then cancels with `.matchedExcludedCredential` when an excluded descriptor matches a stored passkey. The database is saved first and `completeRegistrationRequest` runs only after the save succeeds, so the relying party never receives a credential that was not persisted. Every request still ends in a completion or cancel; an unsupported or malformed one cancels with `.failed`.

### What the extension may touch

- No network. The Mac extension's sandbox grants no network entitlement, `PrivacyInfo.xcprivacy` declares no collection, and `FaviconService` is compiled in but never called. Picker rows show an entry's custom icon (`Meta/CustomIcons`, passed in as `customIcons`) and, on iOS with website icons on, the favicon the app already cached in the App Group; the extension never fetches one. `FaviconEntryIconView`, which can fetch, is app-only. Revisit the manifest's required-reason entries when the allow-list changes.
- Clipboard: only the iOS branch of `ClipboardService` is called from here (verification-code copy; the system pasteboard expiration outlives the process). The macOS branch clears with an in-process timer that dies with the extension, so the coordinator gates the copy on `#if os(iOS)`.
- App Group writes go only through the services in `../KeeForge/Services/Persistence/AGENTS.md`.
- `com.keevault.sharedkeychain` must stay first in both extension entitlements files (rule in `../KeeForge/Services/Security/AGENTS.md`). `KeeForgeMacAutoFill` mirrors the iOS extension's single group and enables Hardened Runtime with zero `com.apple.security.cs.*` exceptions.

## macOS

- `.toolbar` and `.searchable` do not render in the macOS AutoFill panel: SwiftUI routes them to the window's `NSToolbar`, and the system credential-provider window has none. Every view the Mac shell hosts must draw its own title, search, switcher, and exit inside the view (`AutoFillMacChrome.swift`). A toolbar-only Cancel compiles, passes every unit test, and ships a panel the user cannot leave, blocking the calling app.
- The Mac extension fills passwords, passkeys, and one-time codes (`ProvidesPasswords`, `ProvidesPasskeys`, `ProvidesOneTimeCodes` in `InfoMac.plist`; codes need macOS 15, the deployment floor) and saves passkey registrations.
- `ASSavePasswordRequest`, `ASGeneratePasswordsRequest`, `ASGeneratedPassword`, `completeSavePasswordRequest`, and `completeGeneratePasswordRequest` are `API_UNAVAILABLE(macos)` (rechecked against the 27.0 SDK headers). The coordinator's save and generate surface is `#if os(iOS)`, the Mac shell's equivalents are unreachable stubs, and `InfoMac.plist` omits the `Supports*PasswordCredentials*` keys.
- Identity store: whether `ASCredentialIdentityStoreState.supportsIncrementalUpdates` is set depends on the macOS release. Where it is false (recorded for a real enabled provider on 26.5, not re-verified), `saveCredentialIdentities` means "pass all identities", `removeCredentialIdentities` is unsupported, and the system store holds one database's identities, the most recently unlocked AutoFill-enabled one, so Safari suggests from it alone. A tapped suggestion still unlocks its owning database; the switcher and `defaultAutoFillDatabase` keep the others reachable. macOS 27.0.1 reports the flag true for an enabled provider, yet enumeration returns private SafariFoundation objects (`SFPasswordCredentialIdentity`, `SFOneTimeCodeCredentialIdentity`) with no `ASCredentialIdentity` conformance and no `recordIdentifier`; iOS 27.0.1 on a physical iPhone does the same. `CredentialIdentityStoreManager` then publishes without enumerating (`../KeeForge/Services/AutoFill/AGENTS.md`), which on a physical iPhone was verified to reach Safari; the macOS 27.0.1 store was only read, not written, so additive saves there are unverified. It gates on the runtime flag, not `#if os(macOS)`.

- Pending-local encrypted sources use exclusive immutable creation and the shared persistence owner. A revoked or unavailable owner refuses writes without changing already parsed credentials; source export/recovery is offered by the app without unlocking.

## Tests

In `../KeeForgeTests/` (run on iOS, and on macOS through `KeeForgeMacTests`, which compiles that folder):

- `AutoFillMemoryLimitTests`, `KDFExecutionPolicyTests`: the memory and time guards.
- `CredentialProviderCoordinatorTests` first for any coordinator change, then `CredentialProviderSaveTests`, `CredentialProviderPickerCreationTests`, `CredentialProviderRegistrationTests`.
- `CredentialProviderShellMacTests` (`KeeForgeMacTests` only): Mac shell routing and cleanup.
- `CredentialIdentityStoreManagerTests`, `CredentialMatcherTests`, `PasskeyCryptoTests` (in `PasskeyTests.swift`), `SharedVaultStoreTests`. The matching rules themselves are tested in `../Packages/SiteMatching/Tests`.

## See also

- `../KeeForge/Services/AGENTS.md`: save paths, pending uploads, the shared-source allow-list rule
- `../KeeForge/Services/AutoFill/AGENTS.md`, `../KeeForge/Services/Security/AGENTS.md`
- `../KeeForge/AGENTS.md`: KDBX compatibility; `../KeeForgeMac/SECURITY.md`, `../docs/threat-model.md`

- Password save, picker creation, website addition and passkey registration end committed/unknown save outcomes with a warning and cancellation. Known outcomes update installed tree/SHA without completing or republishing successful credentials; lock/request-identity guards still reject obsolete callbacks.

- A local unlock binds encrypted bytes and source identity in one coordinated read and captures the owner epoch before IO. Final quick/express-key publication validates that proof and the current reference/revocation under list-lock then owner flock, held through keychain-only writes. Blocking publication does not discard valid parsed credentials or fail filling. Legacy registry cleanup occurs separately outside flock; cleanup clears the in-memory read proof.
