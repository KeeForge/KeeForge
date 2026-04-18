# ViewModels Folder

Observable app state lives here. Keep business rules here and keep views thin.

## Main View Models

- `DatabaseListViewModel.swift` owns the database list screen: add/remove/reorder, quick launch, nicknames, read-only toggles, key-file association, cloud database selection, row-status derivation, pending-upload counts/conflicts, manual "push pending changes", and the Dropbox write-scope upgrade banner state.
- `DatabaseViewModel.swift` owns one database session: unlock state machine, local/cloud file resolution, draft/save state, local-vs-cloud save routing, expected Dropbox rev tracking, save-conflict detection, synced-folder edit acknowledgments, search, sorting, compact + regular-width selection/navigation state, inactivity lock, biometric unlock, and shared AutoFill cache refresh after both unlock and save.
- `EntryEditViewModel.swift` owns entry form state for both create and edit flows, including tag/custom-field normalization, TOTP field shaping, passkey-preserving round trips, and dirty-state tracking for the edit UI.
- `TOTPViewModel.swift` owns live TOTP code refresh and countdown state for entry-detail UI.
- `CloudFileBrowserSession.swift` owns account selection plus cloud-provider authentication state for the cloud database picker.
- `CloudFolderBrowserViewModel.swift` owns folder browsing, search text, loading, and load-error state for the cloud file browser.

## Guidance

- These types are `@MainActor @Observable`; heavy work should delegate to services or detached tasks and only publish the final UI state back here.
- `DatabaseViewModel.State`, `failedAttempts`, `lockCycleID`, `draft`, `openTimeSHA512`, `saveConflict`, the captured cloud `expectedRev`, the session-key lifecycle, and the selected group/entry state are the main security and navigation invariants.
- Stage entry edits through `DatabaseDraft` plus `save()` rather than mutating `rootGroup` directly and reconstructing save state afterward; `EntryEditViewModel` should only emit `EntryDraftPayload` and local dirty-form state.
- If you change sort, search, or navigation/selection state, verify the matching unit tests and the targeted UI test class.
- Search for `CloudFileBrowserViewModelTests` before changing the cloud browser flow.
- Relevant tests usually live in `../../KeeForgeTests/DatabaseListViewModelTests.swift`, `../../KeeForgeTests/DatabaseViewModelTests.swift`, `../../KeeForgeTests/PendingUploadDrainerTests.swift`, `../../KeeForgeTests/EntryEditViewModelTests.swift`, `../../KeeForgeTests/TOTPViewModelTests.swift`, `../../KeeForgeTests/AutoLockTests.swift`, and `../../KeeForgeTests/SortOrderTests.swift`.
