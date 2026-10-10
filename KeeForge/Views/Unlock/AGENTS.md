# Unlock Views

**Scope:** unlocking one database: password and key-file entry, the biometric and hardware-key affordances, and the failure screen. Folder-wide UI rules are in `../AGENTS.md`.

## Ownership

- Unlock outcome, lockout, failure classification (`DatabaseOpenFailure`), and relinking are owned by `DatabaseViewModel` (`../../ViewModels/AGENTS.md`). This view only gathers the key parts and renders what the failure allows.
- `UnlockKeyFileSelection` reads a picked key file off the main actor and rejects cancelled or replaced results. `UnlockView` cancels it on disappearance, and an associated-key load must not replace a manual selection.

## Invariants

### macOS password field

- On macOS the password field is `MacUnlockPasswordField`, an AppKit field. A focused `NSSecureTextField` turns on secure event input, which bypasses every app-level key hook (`NSEvent` monitors, `.keyboardShortcut`, `.onExitCommand`, `.onKeyPress`). Return and Escape are caught at the field editor's `doCommandBySelector`; do not move them back to SwiftUI.
- Initial focus on macOS belongs to `MacInitialFocus`. It re-applies only while the responder it displaced (the sidebar, after a row click) still holds focus, so a deliberate focus change is never undone.
- `@FocusState passwordFocused` is bound on iOS only. Setting it on macOS does nothing; do not rely on it to move focus there.

### Failure screen and pickers

- The password form stays below the failure whenever `DatabaseOpenFailure.canRetryUnlock` holds, which includes every biometric failure. Try Again repeats quick unlock only while `canRetryQuickUnlock`, so an unreadable saved key sends the user to the password.
- The key-file picker and Locate Database File share one `.fileImporter` through `PickerPresentationState<FilePickerTarget>`; a second importer on the same view does not present reliably. The target outlives dismissal so the completion still knows what was picked.
- Locate Database File shows only while `canRelinkDatabaseFile`. That includes any non-timeout failure while `DatabaseReference.hasUnverifiedRelink`, because a wrong pick fails as a wrong password.

### Biometrics, hardware key, padlock

- On the Mac app the biometric button is only ever an explicit action, never a lifecycle auto-unlock. Its label and caption come from `DatabaseViewModel.biometricLabel` / `biometricCaption`.
- The Hardware Key row appears only when the device offers a transport or the database already has one stored. A YubiKey alone is a valid key, so Unlock is enabled with no password or key file. Cancel during a challenge cancels only the YubiKey request.
- The header padlock starts shut and replays open-to-shut only when `didManuallyLock` says the user pressed Lock. Opening from the list must not animate.

## Tests

- `MacUnlockPasswordFieldTests` (focus and field-editor routing), `UnlockKeyFileSelectionTests`, `HardwareKeyUnlockTests`.
- UI: `UnlockFlowUITests`, `KeyFileUnlockUITests`, `LockUnlockUITests`.

## See also

- `../AGENTS.md`, `../../ViewModels/AGENTS.md`, `../../App/AGENTS.md` (auto-unlock)
- `../../../KeeForgeMac/SECURITY.md`
