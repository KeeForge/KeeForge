# Slice 04: Local file save with backups and conflict detection

> Parent: [`epic.md`](./epic.md) · Depends on: 02, 03

## Goal

Wire slices 02 and 03 together for **local-file** databases: the user makes edits via a `DatabaseDraft`, the app encrypts the result via `KDBXWriter`, takes a backup of the existing file, atomically replaces the original via temp+rename through `NSFileCoordinator`, and refuses the save if the file on disk has changed since open. After this slice, a complete edit-and-save loop works for local databases — no UI yet, but the underlying save action is fully testable and safe enough to be triggered from a button in slice 06.

## Scope

**In:**

- A new `LocalDatabaseSaver` enum with one entry point: `save(draft:reference:compositeKey:openTimeSHA512:) async throws -> SaveResult`. The `SaveResult` is one of `.saved(newSHA512: Data)` or `.conflict(remoteSHA512: Data, remoteData: Data)`.
- Inside that one function:
  1. Wrap the entire save in a `UIApplication.beginBackgroundTask(withName: "DatabaseSaving")` so an inopportune background-transition mid-write doesn't truncate the file. Cleanup in `defer`. (KeePassium does the same in `DatabaseSaver.startBackgroundTask`, `KeePassiumLib/KeePassiumLib/DatabaseSaver.swift:104`.)
  2. Resolve the file URL from the `DatabaseReference` via the existing security-scoped bookmark machinery.
  3. Read the current bytes through `CoordinatedFileReader.readData(from:)`.
  4. Compute SHA512 of those bytes; compare against `openTimeSHA512`. If they differ, return `.conflict` immediately — do not encrypt, do not write.
  5. Encrypt the draft via `KDBXWriter` (off-main, `Task.detached`).
  6. Take a backup: copy the *current* file bytes (the ones we just read) into `App Group/backups/{databaseId}/{timestamp}.kdbx`. Trim to last 5.
  7. Write the new bytes to a sibling temp file in the same directory; use `NSFileCoordinator` writing intent; then `FileManager.replaceItemAt:withItemAt:backupItemName:` to atomically swap. (Explicitly **not** plain `data.write(to:options:[])` — KeePassium uses that path in `LocalDataSource.swift:68` and has shipped truncation bugs as a result.)
  8. Compute SHA512 of the new bytes and return `.saved(newSHA512:)`.
- Extend `DatabaseViewModel` with:
  - A `var draft: DatabaseDraft?` (set when the user starts editing, replaced as edits are applied).
  - A `var openTimeSHA512: Data?` captured at unlock (computed from the bytes we already read in `loadEntries`-equivalent).
  - A `func save() async` entry point that calls `LocalDatabaseSaver.save(...)` for local-source references and routes to slice 05 for cloud-source references (via a switch on `databaseReference.source`).
  - On `.saved`, replace the in-memory tree with the now-clean draft, update `openTimeSHA512`, clear `isDirty`.
  - On `.conflict`, surface a `SaveConflict` published value the view layer can read.
- A new App-Group-scoped backup directory at `Library/Application Support/backups/{databaseId}/`. Created lazily. Auto-pruned to 5 newest files on every successful save.
- Provider-agnostic SHA512 computation utility (`KDBXCrypto.sha512` already exists; just expose it for callers outside `KDBXParser`).
- Extend `DatabaseListStore` with `databaseBackupDirectoryURL(for: DatabaseReference)` and a small `recentBackups(for:)` accessor (the latter is for slice 06's potential "view backups" UI; for v1 it's not surfaced but the API is needed for tests).

- A new `isReadOnly: Bool` field on `DatabaseReference` (Codable, default `false`, persists in `DatabaseListStore`). The save path checks this flag at the very top of `LocalDatabaseSaver.save(...)` and the `DatabaseViewModel.save()` entry point and refuses with a typed `SaveError.databaseIsReadOnly` if set. The flag is set by the user via the `DatabaseRowView` context menu (added in this slice — small surface) and by the synced-folder interstitial below. **The flag is referenced from slices 06 and 07 as well**, where the edit UI is gated and the AutoFill extension's password-creation handler refuses the request — those slices each add their own guard at the named entry points; this slice only owns the storage and the save guard.
- A new `SyncedFolderDetector` service that, given a `DatabaseReference` with non-nil `bookmarkData`, resolves the security-scoped URL and inspects it for known third-party file providers via:
  - `URL.isUbiquitousItem` for iCloud Drive.
  - The file-provider domain identifier for the resolved URL via `NSFileProviderManager.getDomainsWithCompletionHandler` (or `NSFileProviderManager.manager(for:)`), checked against a known set of identifiers: `com.dropbox.Dropbox.FileProvider`, `com.google.Drive.FileProviderExtension`, `com.microsoft.skydrive.OneDriveFileProvider`, `com.box.BoxFileProvider`. The exact identifiers should be verified at implementation time against current builds of each app and documented inline in the source.
  - Returns one of: `.iCloudDrive`, `.dropbox`, `.googleDrive`, `.oneDrive`, `.box`, `.unknownThirdParty(domainIdentifier: String)`, or `.notSynced`.
  - The list is intentionally non-extensible — third-party providers we don't recognize fall through to `.unknownThirdParty`, which still triggers the warning. We are not maintaining an allowlist.
- A first-edit interstitial for `.local`-source databases whose detector result is anything other than `.notSynced`. The interstitial fires the first time the user attempts to enter edit mode (slice 06 calls into a new `DatabaseViewModel.acknowledgeEditingIfNeeded() async -> AcknowledgmentResult` before opening the editor — slice 04 owns the implementation, slice 06 calls it). The acknowledgment state is persisted on `DatabaseReference` as `var editsAcknowledgedAt: Date?` (Codable, nil means "never acknowledged"). The interstitial copy is provider-specific when known and generic when not:
  - **Known provider (e.g. Dropbox):** *"This database file is stored in Dropbox. The Dropbox app on this device — and on any other device signed into the same account — could overwrite your changes if you both edit the database at the same time. Continue editing only if you keep all writes confined to one device at a time."* Buttons: `Continue editing` (sets `editsAcknowledgedAt = .now`, returns `.acknowledged`) or `Keep read-only` (sets `isReadOnly = true`, returns `.keptReadOnly`).
  - **Unknown third party / generic:** *"This database file may be synced by another app on this device. Concurrent edits from another device or app could overwrite your changes."* Same button options.
  - **iCloud Drive:** *"This database file is in iCloud Drive. iCloud may sync changes from another device while you're editing. We recommend keeping all writes on one device."* Same button options.
  - The interstitial does not fire for `.cloud(...)`-source databases (those go through the rev-checked `CloudDatabaseSaver` and don't have the same risk profile) or for `.local` databases without a `bookmarkData` (e.g. databases created in the App Group container directly).

**Out:**

- Cloud upload — slice 05 calls into a different saver for cloud sources.
- Any UI — slice 06 wires a `Save` button to `DatabaseViewModel.save()`, the read-only ribbon, and calls `acknowledgeEditingIfNeeded()` from the `Edit` button. The `DatabaseRowView` read-only context-menu toggle is the *only* UI ships in slice 04 — it's tiny enough to live with the model change.
- Restoring a backup — backups exist, but no restore UI in v1.
- Conflict resolution UI — slice 06 owns the alert.
- "Make a private copy" — that's a v1.1 candidate, see `epic.md` Out of scope.

## Affected areas

- **New:** `KeeForge/Services/Persistence/LocalDatabaseSaver.swift`.
- **New:** `KeeForge/Services/Persistence/SyncedFolderDetector.swift`.
- **Modified:** `KeeForge/Models/DatabaseReference.swift` — adds `var isReadOnly: Bool = false` and `var editsAcknowledgedAt: Date?`. Both Codable; both default to safe values for migration. The decoder must `decodeIfPresent` so existing on-disk references load correctly.
- **Modified:** `KeeForge/ViewModels/DatabaseViewModel.swift` — adds `draft`, `openTimeSHA512`, `save()`, `discardDraft()`, `acknowledgeEditingIfNeeded() async -> AcknowledgmentResult`. Captures `openTimeSHA512` inside the existing unlock pipeline. The save path checks `databaseReference.isReadOnly` first and surfaces `SaveError.databaseIsReadOnly` if set. Exposes `var isReadOnly: Bool` as a passthrough for the view layer.
- **Modified:** `KeeForge/ViewModels/DatabaseListViewModel.swift` — adds `setReadOnly(_:for:)` mutator and persists through `DatabaseListStore`.
- **Modified:** `KeeForge/Views/DatabaseRowView.swift` — adds the read-only toggle to the context menu (`Toggle("Read-only", isOn: ...)`). Adds a small "READ ONLY" badge on the row when set. Both behind accessibility identifiers below.
- **Modified:** `KeeForge/Services/Persistence/DatabaseListStore.swift` — adds `databaseBackupDirectoryURL(for:)`, `recentBackups(for:)`, `pruneBackups(for:keeping:)`, `setReadOnly(_:for:)`, `acknowledgeEdits(for:)`.
- **Modified:** `KeeForge/Models/KDBXCrypto.swift` — make `sha512(_:)` `internal` (was effectively private to parser).
- **New tests:** `KeeForgeTests/LocalDatabaseSaverTests.swift`, `KeeForgeTests/SyncedFolderDetectorTests.swift`, additions to `KeeForgeTests/DatabaseViewModelTests.swift`, `KeeForgeTests/DatabaseListViewModelTests.swift`, and `KeeForgeTests/DatabaseReferenceTests.swift` (Codable migration).

## KeeForge bits

- **Targets:**
  - `LocalDatabaseSaver.swift` belongs to **both** `KeeForge` and `KeeForgeAutoFill` (slice 07 needs it).
  - `SyncedFolderDetector.swift` belongs to **both** targets — slice 07 also needs to read the read-only flag and (optionally) re-check the synced state if a fresh detection is required.
  - `DatabaseReference.swift` is already shared via the `KeeForge/Models` glob; the new fields go to both targets automatically.
- **project.yml:**
  - Add `LocalDatabaseSaver.swift` and `SyncedFolderDetector.swift` to `KeeForgeAutoFill.sources` (the extension's source list is explicit, not glob-based — see `project.yml:82–99`).
  - `Run xcodegen generate`.
- **Accessibility identifiers** (this slice has only the row context-menu surface; the bigger UI lives in slice 06):
  - **Preserved:** all existing identifiers on `DatabaseRowView`.
  - **New:**
    - `database-row.read-only-toggle`
    - `database-row.read-only-badge`
    - `synced-folder-warning.continue`
    - `synced-folder-warning.keep-read-only`
    - `synced-folder-warning.title` (different copy per provider; tests can match the prefix only)

## Testing

- **Unit:** `KeeForgeTests/LocalDatabaseSaverTests.swift`
  - `test_save_writesValidKDBX_thatReParsesEqualToDraft` — open a fixture, apply a `createEntry`, save to a temp URL (use a dummy `DatabaseReference` pointing into the test scratch directory), re-open the saved file with the original password, assert the new entry is present and original entries are unchanged.
  - `test_save_takesBackupOfPreviousBytes_intoBackupDirectory` — assert a backup file exists in `databaseBackupDirectoryURL(for:)` after save and equals the pre-save bytes.
  - `test_save_prunesBackupsToFiveNewest` — perform 7 saves; assert the backup directory contains exactly 5 files, all the most recent.
  - `test_save_returnsSavedSHA512_thatMatchesNewBytes` — assert the returned hash equals the SHA512 of the file on disk after save.
  - `test_save_remoteChangedSinceOpen_returnsConflict_doesNotWrite` — open a fixture, mutate the file on disk between open and save (simulate via writing different bytes to the same path), call save, assert `.conflict(remoteSHA512:remoteData:)`. Assert the file on disk is the *new* bytes (we did not overwrite).
  - `test_save_atomicReplace_doesNotLeaveTempFiles_onSuccess` — assert the directory contains exactly the original filename after save.
  - `test_save_atomicReplace_failureLeavesOriginalIntact` — simulate a failure during write (e.g. disk full via a stub writer); assert the original file bytes are unchanged.
  - `test_save_underNSFileCoordinator_doesNotDeadlock_whenOtherCoordinatorActive` — start a coordinated read on the same URL on another queue; assert save still completes within a reasonable timeout.
  - Run slice: `xcodebuild test -only-testing:KeeForgeTests/LocalDatabaseSaverTests`.
- **Additions to `DatabaseViewModelTests`:**
  - `test_unlock_capturesOpenTimeSHA512` — invariant.
  - `test_save_onCleanDraft_isNoOp` — calling `save()` with `isDirty == false` does nothing and does not bump `openTimeSHA512`.
  - `test_save_onDirtyDraft_replacesRoot_clearsDraft` — calling `save()` with edits applied results in a new `rootGroup` matching the draft and `draft == nil`.
  - `test_save_onConflict_setsSaveConflict_doesNotClearDraft` — invariant for slice 06's UI.
  - `test_save_whenReadOnly_throwsDatabaseIsReadOnly_doesNotEncrypt` — set `isReadOnly = true`, apply an edit, call `save()`, assert the typed error and that no encryption happened (use a stub `KDBXWriter` that records calls).
  - `test_acknowledgeEditingIfNeeded_localUnsynced_returnsAcknowledged_immediately` — `bookmarkData == nil` short-circuits to `.acknowledged` without prompting.
  - `test_acknowledgeEditingIfNeeded_alreadyAcknowledged_returnsAcknowledged_immediately` — `editsAcknowledgedAt != nil` short-circuits.
  - `test_acknowledgeEditingIfNeeded_dropbox_promptsAndPersistsAcknowledgment` — stub the detector to return `.dropbox`; assert the interstitial fires and selecting `Continue` persists `editsAcknowledgedAt`.
  - `test_acknowledgeEditingIfNeeded_dropbox_keepReadOnly_setsFlag_returnsKeptReadOnly` — selecting `Keep read-only` flips `isReadOnly` and returns `.keptReadOnly`.
  - Run: `xcodebuild test -only-testing:KeeForgeTests/DatabaseViewModelTests`.
- **`SyncedFolderDetectorTests`:**
  - `test_detect_iCloudDriveURL_returnsICloudDrive` — `URL.isUbiquitousItem == true`.
  - `test_detect_dropboxFileProviderDomain_returnsDropbox` — stub `NSFileProviderManager` to return `com.dropbox.Dropbox.FileProvider`; assert `.dropbox`.
  - `test_detect_googleDriveFileProviderDomain_returnsGoogleDrive`.
  - `test_detect_oneDriveFileProviderDomain_returnsOneDrive`.
  - `test_detect_boxFileProviderDomain_returnsBox`.
  - `test_detect_unknownDomain_returnsUnknownThirdParty_withDomainIdentifier` — stub returns `com.example.SyncProvider`; assert `.unknownThirdParty(domainIdentifier: "com.example.SyncProvider")`.
  - `test_detect_appGroupContainerURL_returnsNotSynced` — URL inside the app's own container.
  - `test_detect_securityScopedURLOutsideKnownProviders_returnsNotSynced` — local file picked from device storage, no file provider domain.
  - Run: `xcodebuild test -only-testing:KeeForgeTests/SyncedFolderDetectorTests`.
- **`DatabaseReferenceTests` migration coverage:**
  - `test_decode_legacyJSONWithoutNewFields_setsDefaults` — round-trip a pre-edit-support JSON blob; assert `isReadOnly == false` and `editsAcknowledgedAt == nil`.
  - `test_encodeDecode_withNewFields_roundTrips`.
- **Integration / UI:** N/A — this slice has no UI surface yet.
- **Manual:** N/A.
- **Edge cases that apply:**
  - Database file in a security-scoped location (Files app pick) — saver must call `startAccessingSecurityScopedResource` exactly like the read path.
  - Database file in the App Group container directly.
  - Database file on a read-only filesystem (test fixture mount) — assert a clean error, no partial write.
  - Inactivity lock fires mid-save — slice 06 owns the UX, but the saver must not crash if the session key is invalidated mid-write. Document the contract: the caller must keep the session key alive until `save()` returns.
  - Save while another app instance has the same file open in iCloud Drive (covered by the conflict test).

## Exit criteria

- [ ] All `LocalDatabaseSaverTests` and `DatabaseViewModelTests` additions pass.
- [ ] Encryption + SHA512 + file write all run off the main actor.
- [ ] No force unwraps.
- [ ] Save is wrapped in `UIApplication.beginBackgroundTask` with `defer { endBackgroundTask }` cleanup.
- [ ] On-disk write path uses `FileManager.replaceItemAt:withItemAt:backupItemName:` (atomic), **not** `Data.write(to:options:[])`.
- [ ] Backup directory creation respects the App Group container path conventions used by `DatabaseListStore`.
- [ ] `xcodegen generate` run after the `project.yml` update; `KeeForgeAutoFill` still compiles cleanly.
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG entry

`- Internal: Added a local-file save pipeline with atomic write, automatic backups, and out-of-band-change detection.`
