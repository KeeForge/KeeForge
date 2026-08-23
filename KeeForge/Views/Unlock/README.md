# Unlock Views

Unlocking a single database: password and key-file entry, biometric affordances.

## Screen Map

- `UnlockView.swift` owns password/key-file entry and biometric affordances for one database. Its header padlock: `isSealed` starts shut, and `sealShutIfArrivingFromLock` replays open-to-shut only when `DatabaseViewModel.didManuallyLock` says the user pressed Lock (cleared on open in `../../App/KeeForgeApp.swift`); regular shells only — compact returns to the database list on lock and gets its own transition there. On macOS the master-password field is `MacUnlockPasswordField.swift` (`NSSecureTextField`/`NSTextField` `NSViewRepresentable`): a focused `NSSecureTextField` turns on secure event input, which bypasses every app-level key hook (`NSEvent` local monitors, `.keyboardShortcut`, `.onExitCommand`, `.onKeyPress`), so Return (submit) and Escape (back to the list) are caught at the field editor's `doCommandBySelector`.

Shared UI shells and the folder-wide UI rules live in `../README.md`.
