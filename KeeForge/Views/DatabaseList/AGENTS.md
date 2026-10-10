# DatabaseList Views

**Scope:** the database list, creation, the per-database details hub, master-key and encryption changes, password import, export to Files, and the save-conflict alerts. Folder-wide UI rules are in `../AGENTS.md`; read it first.

## Ownership

- `DatabaseDetailsView` is one screen with two contexts. From the list it gets the app's `DatabaseListViewModel` and an `onSelectKeyFile` closure (the list owns that importer). From an unlocked database it gets `sessionViewModel`, creates its own list view model, and must install the `autoFillEnabledRefreshHandler` bridge itself.
- With a session, nickname, read-only, and sync-policy edits route through the session so it refreshes its own copy of the reference. Session-only rows: AutoFill destination group, Change Master Key, Change Encryption Settings, Sync Now, Import Passwords, App Settings.
- The macOS workspace's Database Details button passes the live session; that is the only way Change Master Key is reachable on macOS.
- The details root is a hub of summary rows. A new setting goes into a page's section, never onto the hub. Row wording lives in the pure `DatabaseSettingsSummary`.
- The per-database AutoFill toggle goes through `DatabaseListViewModel.setAutoFillEnabled`, never the store directly, so disabling removes identities and enabling republishes the open session.
- Each form's work, validation, and cancellation live in its view model (`DatabaseCreationViewModel`, `MasterKeyChangeViewModel`, `EncryptionSettingsViewModel`, `PasswordImportViewModel`). `DatabaseExportPresenter` owns the load, the `.fileExporter`, and the failure alert for every export entry point.

## Invariants

### Database list

- On iOS rows move only in Edit mode (`moveDisabled` plus the shared `EditMode` binding). Otherwise the reorder gesture competes with the long-press context menu and XCTest waits on animations. macOS reorders by drag with no Edit button.
- `isSidebarColumn` is passed in by the host, not read from `horizontalSizeClass`, which a sidebar column reports as compact. It picks `.sidebar` over `.insetGrouped`; the grouped card renders darker than the column on iPadOS and opaque over the material on macOS.
- On macOS the list has no `NavigationStack` of its own; one would paint over the sidebar material.
- Follow-ups to the pending-upload conflict alert and to a swipe action wait before presenting, because a dialog raised while the alert is dismissing or the cell is still open is dropped. Row dialogs stay attached to the row they act on.

### Details and the screens pushed from it

- Importers, sheets, the export presenter, and the file-facts task hang off the `NavigationStack`, not the hub: the hub leaves the screen while a page is pushed, which cancels its tasks and leaves it unable to present.
- That task is keyed on the session's `openTimeSHA512`, which every write through the session replaces, so file facts and backups refresh while the sheet stays open.
- The read-only toggle is disabled for KDBX 3.1 and for a database with a hardware key configured, in both contexts; the savers reject both.
- `MasterKeyChangeView` is pushed inside the details sheet, never a nested sheet. Its back button is hidden so Cancel is the only way out and the edge-swipe cannot abort mid-edit. Cancel and `onDisappear` call `cancelPendingChange()`, so a dismissal during authentication aborts instead of rekeying with cleared fields.
- A master-key save asks for a destructive confirmation and then device-owner authentication. An authentication failure other than a user cancel must surface as an error, not look like success.
- `EncryptionSettingsView` has no confirmation or authentication on purpose: the key does not change and the save keeps a backup. Back and interactive dismissal are disabled while it saves.
- `DatabaseCreationView` blocks dismissal while creating; on disappearance `cancelPendingCreation()` clears secrets and rejects late results. It does not undo a cloud creation that already committed.
- `PasswordImportView` discards its preview on disappearance and on lock, and blocks leaving while importing.

### Save conflict

- `SaveConflictAlertModifier` stacks four mutually exclusive alerts. Acknowledging a failed merge puts the conflict alert back up; a merge failure is never a dead end.

## Tests

- UI: `DatabaseListUITests`, `DatabaseCreationCompactUITests` / `DatabaseCreationRegularWidthUITests`, `MasterKeyChangeUITests`, `EncryptionSettingsUITests`, `SaveConflictMergeUITests`.
- Unit: the four view models' `<Type>Tests`, `DatabaseSettingsSummaryTests`. `PasswordImportViewModelTests` is in `PasswordImportTests.swift`.

## See also

- `../AGENTS.md`, `../Cloud/AGENTS.md`, `../Components/AGENTS.md` (`SettingsSummaryRow`)
- `../../ViewModels/AGENTS.md`: rekey and re-encryption preconditions, conflict and merge policy
- `../../Services/AGENTS.md`: save paths, pending uploads, AutoFill allow-list
