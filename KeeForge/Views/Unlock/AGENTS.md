# Unlock Views

**Scope:** unlocking one database: password and key-file entry, the biometric and hardware-key affordances, opening progress, and the failure and recovery pages. Folder-wide UI rules are in `../AGENTS.md`.

## Ownership

- Unlock outcome, lockout, failure classification (`DatabaseOpenFailure`), and relinking are owned by `DatabaseViewModel` (`../../ViewModels/AGENTS.md`). These views only gather the key parts and render what the failure allows.
- `UnlockView` and `DatabaseOpeningView` are the iPhone and iPad pages and compile only on iOS. The Mac pages are in `Mac/`: `MacUnlockView`, `MacDatabaseOpeningView`, `MacDatabaseRecoveryView` and `MacDatabaseUnavailableView`, sharing `MacLockedPageHeader` and `MacLockedPageLayout`. `MacDatabaseRootView` (`../../../KeeForgeMac/App/`) picks one from `MacDatabaseOpenPage`.
- On Mac the form's state belongs to the window's `MacUnlockFormModel`, owned by `DatabaseWindowController` for the window's life, so a page swap never drops a picked key file. The views keep no key material in `@State`.
- `UnlockKeyFileSelection` reads a picked key file off the main actor and rejects cancelled or replaced results; an associated-key load must not replace a manual selection. `UnlockView` cancels it on disappearance; on Mac the form model owns it.

## Invariants

### macOS password field

- On macOS the password field is `MacUnlockPasswordField`, an AppKit field. A focused `NSSecureTextField` turns on secure event input, which bypasses every app-level key hook (`NSEvent` monitors, `.keyboardShortcut`, `.onExitCommand`, `.onKeyPress`). Return and Escape are caught at the field editor's `doCommandBySelector`; do not move them back to SwiftUI. The inline Unlock button is never the window's default button.
- Initial focus on macOS belongs to `MacInitialFocus`. It re-applies only while the responder it displaced (the sidebar, after a row click) still holds focus, so a deliberate focus change is never undone. The only other focus move is the form's `focusRequest` (after a Touch ID fallback or cancel), applied once after the update.
- The field offers no completion and no content type. The shown variant's field editor refuses copy, cut, drag and Services, so the master password never reaches a pasteboard; paste stays.

### Page layout

- iPhone and iPad draw the design's unlock page: the database's name, file, and storage in the navigation bar, then the password field, Key File and Hardware Key in one card, then Unlock, the biometric button, and Choose Different File.
- The Mac unlock page follows the Unlock board: Touch ID first with an "or" divider and Unlock inline in the field while `biometricUnlockAvailability == .available`, otherwise the field with Show/Hide and an Unlock Database capsule, plus the unavailable note when a saved key exists but Touch ID cannot be used. A wrong attempt empties the field and rings it red. The key-file line, then the inactivity footer, close the page. No Hardware Key row on Mac (no transport).
- While a database opens, iPhone and iPad show `DatabaseOpeningView` under the same navigation-bar title (`databaseNavigationTitle`) with its steps; the Mac shows `MacDatabaseOpeningView` with the same steps and Cancel through `cancelUnlockAttempt` while `canCancelUnlockAttempt`. Both only report progress; Cancel ends the attempt like a manual lock.
- Locked pages scroll only when the window is too short for them (900 x 620 fits the Touch ID page with a card).

### Failure screen and pickers

- A failure the form can fix (`DatabaseOpenFailure.canRetryUnlock`) is a card under the field: `UnlockFailureCard` above the form on iPhone and iPad, `MacUnlockFailureCard` on Mac, whose menu holds Locate Database File… (only while `canRelinkDatabaseFile`, so a Locate no unlock has confirmed can be corrected), Copy Error Details and Send Feedback. Any other failure is the error page on iPhone and iPad, and `MacDatabaseRecoveryView` on Mac with Locate Database File… (only while `canRelinkDatabaseFile`), Reconnect for a server sign-in failure (`MacServerReconnect`: the Connect to Server form as a sheet, then back to the form), Try Again (back to the form) and Remove from List (the coordinator's confirmation and unsaved-work refusal as NSAlerts in that window). Shared actions keep the same identifiers everywhere, and the summary always carries `unlock.error.label`.
- On iPhone and iPad the error page's Try Again repeats quick unlock only while `canRetryQuickUnlock`, so an unreadable saved key sends the user to the password.
- On iOS the key-file picker and Locate Database File share one `.fileImporter` through `PickerPresentationState<FilePickerTarget>`; a second importer on the same view does not present reliably. On Mac both are `NSOpenPanel` sheets on the database window through `MacFilePanels` (`MacUnlockFilePicking`), and a sheet holds back an automatic Touch ID prompt.
- Locate Database File shows only while `canRelinkDatabaseFile`. That includes any non-timeout failure while `DatabaseReference.hasUnverifiedRelink`, because a wrong pick fails as a wrong password.

### Biometrics, hardware key

- The password form and explicit biometric unlock stay available while locked. The app shell owns opt-in automatic prompting; these views never start a lifecycle prompt, and the Mac Touch ID button is the form model's only way to prompt. Button text comes from `DatabaseViewModel.biometricLabel` / `biometricCaption`.
- The iOS Hardware Key row appears only when the device offers a transport or the database already has one stored. A YubiKey alone is a valid key, so Unlock is enabled with no password or key file. Cancel during a challenge cancels only the YubiKey request.

## Tests

- `MacUnlockPasswordFieldTests` (focus, focus requests, field-editor routing, completion and pasteboard rules), `MacFilePanelsTests`, `MacUnlockFormModelTests`, `MacDatabaseOpenPageTests`, `UnlockKeyFileSelectionTests`, `HardwareKeyUnlockTests`, `DatabaseOpeningStepTests`, `MacServerReconnectTests` (Reconnect against the real WebDAV and FTP providers). The window's form lifetime and the missing toolbar: `DatabaseWindowControllerTests`; Remove from List: `MacWindowCoordinatorTests`.
- UI: `UnlockFlowUITests`, `KeyFileUnlockUITests`, `LockUnlockUITests`, `BackoffUITests`; Mac: `MacSmokeUITests` (focus, Return, the key-file sheet, a wrong attempt, Escape), `MacWindowLifecycleUITests` (independent windows, Lock All), `MacDatabaseListUITests` (recovery page Remove from List), audit captures `02`–`02e`.
- Visual: `ViewRenderTests.testUnlockFailureCards` renders `UnlockFailureCard` in each shipped language (`scripts/render-views.sh`).

## See also

- `../AGENTS.md`, `../../ViewModels/AGENTS.md`, `../../App/AGENTS.md` (auto-unlock)
- `../../../KeeForgeMac/SECURITY.md`
