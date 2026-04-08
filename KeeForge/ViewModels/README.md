# ViewModels Folder

Observable app state lives here. Keep business rules here and keep views thin.

## Main View Models

- `DatabaseListViewModel.swift` owns the database list screen: add/remove/reorder, quick launch, nicknames, read-only toggles, key-file association, cloud database selection, and row-status derivation.
- `DatabaseViewModel.swift` owns one database session: unlock state machine, local/cloud file resolution, draft/save state, save-conflict detection, synced-folder edit acknowledgments, search, sorting, inactivity lock, biometric unlock, and shared AutoFill cache refresh.
- `TOTPViewModel.swift` owns live TOTP code refresh and countdown state for entry-detail UI.

## Guidance

- These types are `@MainActor @Observable`; heavy work should delegate to services or detached tasks and only publish the final UI state back here.
- `DatabaseViewModel.State`, `failedAttempts`, `lockCycleID`, `draft`, `openTimeSHA512`, `saveConflict`, and the session-key lifecycle are the main security and save-path invariants.
- If you add entry-edit UI, stage edits through `DatabaseDraft` plus `save()` rather than mutating `rootGroup` directly and reconstructing save state afterward.
- If you change sort, search, or navigation state, verify the matching unit tests and the targeted UI test class.
- `CloudFileBrowserView` keeps some state close to the view layer; search for `CloudFileBrowserViewModelTests` before changing that flow.
- Relevant tests usually live in `../../KeeForgeTests/DatabaseListViewModelTests.swift`, `../../KeeForgeTests/DatabaseViewModelTests.swift`, `../../KeeForgeTests/TOTPViewModelTests.swift`, `../../KeeForgeTests/AutoLockTests.swift`, and `../../KeeForgeTests/SortOrderTests.swift`.
