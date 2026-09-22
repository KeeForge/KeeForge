# Unlock Views

Unlocking a single database: password and key-file entry, biometric affordances.

## Screen Map

- `UnlockView.swift` owns password/key-file entry and biometric affordances for one database. Its header padlock: `isSealed` starts shut, and `sealShutIfArrivingFromLock` replays open-to-shut only when `DatabaseViewModel.didManuallyLock` says the user pressed Lock (cleared on open in `../../App/KeeForgeApp.swift`); regular shells only — compact returns to the database list on lock and gets its own transition there. On macOS the master-password field is `MacUnlockPasswordField.swift` (`NSSecureTextField`/`NSTextField` `NSViewRepresentable`): a focused `NSSecureTextField` turns on secure event input, which bypasses every app-level key hook (`NSEvent` local monitors, `.keyboardShortcut`, `.onExitCommand`, `.onKeyPress`), so Return (submit) and Escape (back to the list) are caught at the field editor's `doCommandBySelector`. Only a first-responder field sees them, so initial focus is owned by `MacInitialFocus` in the same file: it focuses when the field lands in a window and re-applies only while the responder it displaced (the sidebar, after a row click) still holds focus, so a deliberate focus change is never undone. Don't request macOS focus through `@FocusState` here; no view binds it.
- The key-file picker and the failure screen's Locate Database File (`DatabaseViewModel.relinkDatabaseFile(to:)`, offered only while `canRelinkDatabaseFile`: for missing, trashed, or unreadable files, and for any non-timeout failure while `DatabaseReference.hasUnverifiedRelink`, because a wrong pick fails as a wrong password) share one `.fileImporter` through `PickerPresentationState<FilePickerTarget>` (the target outlives the dismissal, so the completion still knows what was picked); a second importer on the same view does not present reliably.

Shared UI shells and the folder-wide UI rules live in `../README.md`.
