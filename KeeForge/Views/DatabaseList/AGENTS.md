# DatabaseList Views

**Scope:** the database list, creation, the per-database details hub, master-key and encryption changes, password import, export to Files, and the save-conflict alerts. Folder-wide UI rules are in `../AGENTS.md`; read it first.

## Ownership

- `DatabaseDetailsView` is iOS only, one screen with two contexts. From the list it gets the app's `DatabaseListViewModel` and an `onSelectKeyFile` closure (the list owns that importer). From an unlocked database it gets `sessionViewModel`, creates its own list view model, and must install the `autoFillEnabledRefreshHandler` bridge itself.
- With a session, nickname, read-only, and sync-policy edits route through the session so it refreshes its own copy of the reference. Session-only rows: AutoFill destination group, Change Master Key, Change Encryption Settings, Sync Now, Import Passwords, App Settings.
- On macOS, Change Master Key and Change Encryption Settings are `MacMasterKeySheet` and `MacEncryptionSettingsSheet`, sheets on the native Database Settings sheet's Security tab, reached from a window's live session (Database Settings… or Database ▸ Change Master Key…). The launcher's settings have no session and offer neither. `MasterKeyChangeView` and `EncryptionSettingsView` are iOS presentations.
- The details root is a hub of summary rows. A new setting goes into a page's section, never onto the hub. Row wording lives in the pure `DatabaseSettingsSummary`.
- The per-database AutoFill toggle goes through `DatabaseListViewModel.setAutoFillEnabled`, never the store directly, so disabling removes identities and enabling republishes the open session.
- Each form's work, validation, and cancellation live in its view model (`DatabaseCreationViewModel`, `MasterKeyChangeViewModel`, `EncryptionSettingsViewModel`, `PasswordImportViewModel`). `DatabaseExportPresenter` owns the iOS load, share-sheet hand-off, and failure alert. On Mac, `.databaseExporter` bridges existing bindings to `MacDatabaseExporter` (native `NSSavePanel` and `NSAlert`); native callers can use the exporter directly. It writes only encrypted KDBX bytes to the picked URL without a temporary file. The iOS hand-off stages a temp file that is deleted when the share sheet closes; the current-copy action is labelled Export Copy on macOS and Share on iOS (`DatabaseExportLabels`), except in iOS Database Details, which says Export….

## Invariants

### Database list

- iPhone and iPad list databases as plain `DatabaseListRow`s; the Mac's Databases window is AppKit (`../../../KeeForgeMac/App/MacDatabasesLauncherViewController.swift`). The badges and notices on both come from the pure `DatabaseRowStatusSummary` (the Mac row shows the first notice as its problem line); keep identifiers on the same meaning on both platforms. Pending uploads are a notice counted in words, not a badge. With Show Usage Stats off, a row says neither when its database was last opened nor when it last synced; sync warnings still show. On iOS a badge never truncates: badges move under the name, then one per line.
- On iOS rows move only in Edit mode (`moveDisabled` plus the shared `EditMode` binding). Otherwise the reorder gesture competes with the long-press context menu and XCTest waits on animations.
- `isSidebarColumn` is passed in by the host, not read from `horizontalSizeClass`, which a sidebar column reports as compact. It picks `.sidebar` over `.insetGrouped`; the grouped card renders darker than the column on iPadOS.
- `DatabaseListView`, `DatabaseDetailsView` and `DatabaseCreationView` are iOS only. The Mac uses native sheets and alerts over this folder's view models (`../../../KeeForgeMac/App/`); of this folder's views it uses only the export presenter's `.databaseExporter` bridge, in the launcher and in `MacDatabaseSettingsSheet`.
- On iOS, follow-ups to the pending-upload conflict alert and to a swipe action wait before presenting, because a dialog raised while the alert is dismissing or the cell is still open is dropped. Row dialogs stay attached to the row they act on. The Mac Databases window queues the same follow-ups natively (`MacDatabasesAlerts`).

### Details and the screens pushed from it

- Importers, sheets, the export presenter, and the file-facts task hang off the `NavigationStack`, not the hub: the hub leaves the screen while a page is pushed, which cancels its tasks and leaves it unable to present.
- That task is keyed on the session's `openTimeSHA512`, which every write through the session replaces, so file facts and backups refresh while the sheet stays open.
- The read-only toggle is disabled for KDBX 3.1 and for a database with a hardware key configured, in both contexts; the savers reject both.
- The master-key, encryption and import sheets register cancellation with their shell so teardown clears pending work synchronously.
- `MasterKeyChangeView` is pushed inside the details sheet, never a nested sheet. Its back button is hidden so Cancel is the only way out and the edge-swipe cannot abort mid-edit. Cancel and `onDisappear` call `cancelPendingChange()`, so a dismissal during authentication aborts instead of rekeying with cleared fields.
- A master-key save asks for a destructive confirmation and then device-owner authentication. An authentication failure other than a user cancel must surface as an error, not look like success.
- `EncryptionSettingsView` has no confirmation or authentication on purpose: the key does not change and the save keeps a backup. Back and interactive dismissal are disabled while it saves.
- `DatabaseCreationView` blocks dismissal while creating; on disappearance `cancelPendingCreation()` clears secrets and closes the creation lifetime. A late cloud receipt is retained without registering or opening the database.
- `PasswordImportView` discards its preview on disappearance and on lock, and blocks leaving while importing.
- A master-key save asks for a destructive confirmation and then device-owner authentication, which runs in `MasterKeyChangeViewModel.performConfirmedChange`, so nothing is written before both. An authentication failure other than a user cancel must surface as an error, not look like success.
- On Mac, Cancel, Escape and the parent's Done are disabled while the key or encryption change runs; lock or close ends the sheets and clears the typed fields but never cancels the write. A key file created there is written only to the save-panel URL, its buffer wiped, then read back and bookmarked.
- `EncryptionSettingsView` has no confirmation or authentication on purpose: the key does not change and the save keeps a backup. Back and interactive dismissal are disabled while it saves. The Mac sheet's Benchmark times one derivation off the main actor only when clicked; a selection change, Save or closing discards its result. One benchmark derivation runs at a time app-wide, none starts while that database saves, and Save waits for a running one to finish before re-encrypting.
- `DatabaseCreationView` blocks dismissal while creating; on disappearance `cancelPendingCreation()` clears secrets and rejects late results. It does not undo a cloud creation that already committed.
- `PasswordImportView` discards its preview on disappearance and on lock, and blocks leaving while importing. Mac File ▸ Import Passwords… and empty-group import use `MacPasswordImportSheet`, the native form shell and group picker. It rechecks the workspace import guard on confirmation and discards plaintext on import, shell cancellation, and lock; the CSV is read once in place and never copied.

### Save conflict

- On iOS `SaveConflictAlertModifier` stacks four mutually exclusive alerts; on Mac the workspace's `MacWorkspaceAlerts` presents them as `NSAlert`s. Acknowledging a failed merge puts the conflict alert back up; a merge failure is never a dead end.

- Database Details enumerates pending-local recovery independently of unlock and target SHA. Exports read a receipt-verified full encrypted source and need its original key when opened. Discard is a separate destructive confirmation over a captured snapshot; export failure never invokes or authorizes it. Process-local owner notifications and foreground refresh both reload source and backup lists independently of the database SHA. Foreground refresh is the cross-process visibility boundary; Foundation NotificationCenter is not an interprocess signal.

## Tests

- UI: `DatabaseListUITests`, `DatabaseCreationCompactUITests` / `DatabaseCreationRegularWidthUITests`, `MasterKeyChangeUITests`, `EncryptionSettingsUITests`, `SaveConflictMergeUITests`.
- Unit: `MacMasterKeySheetTests` covers confirm → authenticate → change, disabled Cancel/Escape/Done while writing, and lock ending the sheets while the write continues; `MacEncryptionSettingsSheetTests` covers Save gating, busy state and benchmark cancellation. `MacPasswordImportSheetTests` covers the picked URL, single read, frozen confirmation, close/lock discard and completion. `MacDatabaseExporterTests` covers current/backup byte identity, cancellation, failure and direct writes. The four view models' `<Type>Tests`, `DatabaseSettingsSummaryTests`, `DatabaseRowStatusSummaryTests`.
- Visual: `ViewRenderTests.testDatabaseListRows` renders every row state in each shipped language and three layouts (`scripts/render-views.sh`). Check it after changing row text or layout. `PasswordImportViewModelTests` is in `PasswordImportTests.swift`.

## See also

- `../AGENTS.md`, `../Cloud/AGENTS.md`, `../Components/AGENTS.md` (`SettingsSummaryRow`)
- `../../ViewModels/AGENTS.md`: rekey and re-encryption preconditions, conflict and merge policy
- `../../Services/AGENTS.md`: save paths, pending uploads, AutoFill allow-list

- Master-key and encryption-settings warnings complete that invocation and replace Save with acknowledgement. Keep entered master-key material until acknowledgement/dismissal; field edits cannot re-enable a completed request. Local recovery distinguishes target-file durability from cleanup-record uncertainty. Its destructive action is independent of export and explicitly warns that abandoning key publication does not undo an installed key change.
- An unlocked session can export its retained unsaved draft through the existing native exporter while recovering local publication. The exported full snapshot uses the unlocked session's key; locked source exports continue to use exact encrypted receipts without restoring secrets.

- The draft-export capability is outside optional owner/witness rows and requires the same unlocked local dirty session. Active recovery replaces normal conflict Merge/Reload promises with actionable Details/export; durable settlement resumes the existing conflict actions.

- Distinguish a known committed ordinary file from an unknown save outcome. Known output supports a new explicit save without destructive record discard; neither acknowledgement nor activation resends the previous operation. Keep file-durability and record warnings truthful.

- Cloud Details links to Cloud Recovery independently of a session, including when removal refuses pending journal ownership. On iOS, an explicit second confirmation allows removal of a database with verified encrypted recovery copies for unconfirmed uploads. Local recovery and source semantics stay separate.
- Local recovery content is shared with native Mac Database Settings; each platform owns its confirmation and encrypted export presenter. Confirmation copy belongs to `PendingLocalRecoveryViewModel` so a known commit is never described as an unknown write on another platform.
