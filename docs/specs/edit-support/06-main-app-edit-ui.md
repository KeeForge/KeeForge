# Slice 06: Entry edit UI in main app

> Parent: [`epic.md`](./epic.md) · Depends on: 03, 04

## Goal

Add the user-facing surface in the main app that lets people create, edit, and delete entries — backed by `DatabaseDraft` (slice 03) and `DatabaseViewModel.save()` (slice 04, plus slice 05 if cloud). After this slice, a user can fully edit entries on a local database in the main app, with discard-changes confirmation, lock-during-edit handling, save-button states, and the conflict-resolution alert that decides between "reload" and "save as conflict copy". Cloud-only behavior (re-auth banner, cloud-conflict copy naming) is hooked up here too — the underlying mechanics already exist after slice 05.

## Scope

**In:**

- A new `EntryEditView` (SwiftUI) used for both create and edit. Form fields: title, username, password, URL, notes, tags, custom fields list (add/remove rows), TOTP setup. Read-only display of fields like passkey credentials and unknown XML — these are preserved through the draft but not editable in v1.
- A "strong password generator" button on the password field that opens a small sheet exposing length, charset, and "regenerate" — uses a new `PasswordGenerator` utility (so slice 07's AutoFill flow can reuse it).
- Wire-ups (each gated on `databaseReference.isReadOnly`):
  - `EntryDetailView`: add a navigation-bar `Edit` button that pushes `EntryEditView` populated from the current entry. **Hidden** when `isReadOnly == true`. The button calls `viewModel.acknowledgeEditingIfNeeded()` first (slice 04 owns the implementation); if the user picks `Keep read-only` in the synced-folder interstitial, the editor is not pushed and the read-only ribbon appears immediately.
  - `GroupListView`: add a navigation-bar `+` button that pushes `EntryEditView` in create mode, with the current group as the parent. **Hidden** when `isReadOnly == true`. Same `acknowledgeEditingIfNeeded()` gate.
  - `EntryListView` and `SearchView`: swipe-to-delete with a confirmation alert. Default: send to recycle bin. Long-press → "Delete permanently" alternative. **Both swipe actions hidden** when `isReadOnly == true`.
- Read-only ribbon: a thin banner at the top of `EntryDetailView`, `GroupListView`, and the entry list when `databaseReference.isReadOnly == true`, with copy *"Read-only mode — toggle in the database list to enable editing."* The ribbon has accessibility identifier `database.read-only-ribbon` and is the visible signal that explains why edit affordances are missing.
- A `Save` toolbar item on the database screen (or wherever the global "this database has unsaved changes" surface lives — see open question below). Disabled when `!viewModel.isDirty`. Spinner during save. Disabled while a save is in flight. Reflects `viewModel.saveError` as an alert when set.
- Discard-changes confirmation: any navigation away from `EntryEditView` while the entry form is dirty pops a "Discard changes?" alert with destructive action.
- Conflict resolution alert: when `DatabaseViewModel.saveConflict` is set, present an alert with three options:
  - **Reload and re-edit** — discard the local draft, re-open from disk/cloud, return user to the entry list. The user's edits are lost, by design.
  - **Save as conflict copy** — write the encrypted draft to a sibling file `name (conflict yyyy-MM-dd HHmm).kdbx` next to the original. For local files, this is a sibling file with the same security-scoped parent. For cloud files, this uploads to the same Dropbox folder with the suffixed name (no rev required, since it's a new file).
  - **Cancel** — keeps the draft alive in memory; user can keep editing.
- Lock-during-edit:
  - The inactivity timer continues to fire while editing, but if it would lock and `isDirty == true`, the lock prompt becomes a "Lock and discard unsaved changes?" confirmation. If the user says yes (or the manual lock action is invoked), the draft is discarded and lock proceeds.
  - On unlock, the user is returned to a clean state (no preserved draft from before lock).
- Cloud re-auth banner: when `saveError == .writeScopeRequired`, present a banner above the entry list with "Reconnect Dropbox" CTA that calls into `DropboxCloudProvider.authenticate(...)` with the new scope.
- Accessibility identifiers added to every new control so the slice 07 UI tests (and any future ones) can drive the editor end-to-end.

**Out:**

- Group editing.
- Database settings editing.
- Backup browsing/restore UI (backups exist on disk but no surface).
- AutoFill flows — slice 07.
- Manual conflict merge — out of scope for v1.

## Affected areas

- **New:**
  - `KeeForge/Views/EntryEditView.swift`.
  - `KeeForge/Views/PasswordGeneratorSheet.swift`.
  - `KeeForge/Services/AutoFill/PasswordGenerator.swift`.
  - `KeeForge/Views/SaveConflictAlert.swift` (or as a `.alert(...)` modifier on the existing host view — author's call).
- **Modified:**
  - `KeeForge/Views/EntryDetailView.swift` — adds the `Edit` toolbar button.
  - `KeeForge/Views/GroupListView.swift` — adds the `+` toolbar button and the swipe-to-delete actions.
  - `KeeForge/Views/EntryListView.swift` — adds swipe-to-delete (if it's a separate surface from `GroupListView`).
  - `KeeForge/Views/SearchView.swift` — swipe-to-delete on search results.
  - `KeeForge/ViewModels/DatabaseViewModel.swift` — exposes `isDirty`, `saveError`, `saveConflict`, `isSaving`. Already has `draft`, `save()`, `discardDraft()` from slice 04. Adds `saveAsConflictCopy()` and `reloadDiscardingDraft()` for the conflict alert actions. Adds `lockRequest(force:)` that the host view checks before discarding.
- **New tests:**
  - `KeeForgeTests/PasswordGeneratorTests.swift`.
  - `KeeForgeTests/EntryEditViewModelTests.swift` (for any helper view models the SwiftUI form spawns).
  - Additions to `KeeForgeTests/DatabaseViewModelTests.swift` for `saveAsConflictCopy` and `reloadDiscardingDraft`.
  - `KeeForgeUITests/EntryEditUITests.swift` — covers the happy paths with accessibility identifiers from this slice.

## KeeForge bits

- **Targets:**
  - `EntryEditView.swift`, `PasswordGeneratorSheet.swift`, `SaveConflictAlert.swift` — `KeeForge` only.
  - `PasswordGenerator.swift` — **both** `KeeForge` and `KeeForgeAutoFill` (slice 07 reuses it).
- **project.yml:**
  - Add `KeeForge/Services/AutoFill/PasswordGenerator.swift` to `KeeForgeAutoFill.sources` (everything else lives under `KeeForge/Views`, which the extension does not include).
  - `Run xcodegen generate`.
- **Accessibility identifiers** (add and preserve):
  - **Preserved:** every existing identifier on `EntryDetailView`, `GroupListView`, `EntryListView`, `SearchView`, `UnlockView` — slice 06 adds buttons but does not rename existing controls. Audit the diff before merging to confirm.
  - **New:**
    - `entry-edit.title-field`, `entry-edit.username-field`, `entry-edit.password-field`, `entry-edit.url-field`, `entry-edit.notes-field`, `entry-edit.tags-field`.
    - `entry-edit.custom-field.add`, `entry-edit.custom-field.row` (parameterized with the field key for tests).
    - `entry-edit.totp-setup`.
    - `entry-edit.save`, `entry-edit.cancel`, `entry-edit.delete`.
    - `entry-edit.password-generator-button`, `password-generator.length-slider`, `password-generator.charset-toggle`, `password-generator.regenerate`, `password-generator.use`.
    - `database.save`, `database.unsaved-indicator`, `database.read-only-ribbon`.
    - `entry-list.add-entry`, `entry-row.delete-swipe`, `entry-row.delete-permanent`.
    - `save-conflict.reload`, `save-conflict.save-as-copy`, `save-conflict.cancel`.
    - `cloud-reauth-banner`, `cloud-reauth-banner.reconnect`.

## Testing

- **Unit:** `KeeForgeTests/PasswordGeneratorTests.swift`
  - `test_generate_defaultLength_returnsExpectedLength` — assert default length matches the spec (e.g. 20).
  - `test_generate_charsetIncludes_appliesAllCharacterClasses` — when uppercase, lowercase, digits, symbols are all on, the result contains at least one of each (probabilistically; use a fixed seed in tests).
  - `test_generate_excludeAmbiguous_dropsConfusingChars` — assert no `Il0O` etc. when toggled.
  - `test_generate_isHighEntropy` — assert min entropy >= 80 bits at default settings.
- **Unit:** Additions to `DatabaseViewModelTests`
  - `test_saveAsConflictCopy_local_writesSiblingFile_clearsConflict` — exercise via `LocalDatabaseSaver` injected stub.
  - `test_saveAsConflictCopy_cloud_uploadsSuffixedFile_clearsConflict` — exercise via `UITestDropboxCloudProvider` stub.
  - `test_reloadDiscardingDraft_replacesRoot_withFreshTreeFromDisk_clearsDraft`.
  - `test_lockWhileDirty_requiresExplicitConfirmation`.
- **Integration / UI:** `KeeForgeUITests/EntryEditUITests.swift`
  - `test_create_entry_savesAndShowsInList` — open `demo.kdbx`, tap `entry-list.add-entry`, fill required fields, tap `entry-edit.save`, tap `database.save`, verify entry appears.
  - `test_edit_entry_savesNewValue` — open existing entry, edit, save, verify.
  - `test_delete_entry_softDelete_movesToRecycleBin` — verify the entry is no longer in its parent group and is visible under the recycle bin.
  - `test_discard_unsavedEdit_promptsConfirmation`.
  - `test_passwordGenerator_producesNonEmptyPassword`.
  - `test_lockWhileDirty_promptsConfirmation_thenLocks`.
  - `test_saveConflict_offersReloadAndConflictCopy` — set up the test by mutating the file under the app between unlock and save (use a UI-test hook on `DatabaseListStore`).
  - `test_readOnlyDatabase_hidesEditAffordances_showsRibbon` — toggle read-only via `database-row.read-only-toggle`, open the DB, assert `database.read-only-ribbon` exists, `entry-list.add-entry` is absent, `entry-detail` does not show an Edit button, swipe-to-delete is unavailable.
  - `test_readOnlyDatabase_toggleOff_restoresEditAffordances` — flip the toggle back, reopen, assert all affordances return.
  - Run UI: `xcodebuild test -only-testing:KeeForgeUITests/EntryEditUITests`.
- **Manual:**
  - Edit an entry, lock the app from the foreground, confirm the discard prompt fires.
  - Open the app's Settings → Edit a tag → save → quit → reopen → verify the change persisted.
  - Trigger a conflict by hand: open the database, modify the file via Files.app, return to KeeForge, save, verify the conflict alert.
  - For cloud users: revoke the Dropbox app from the Dropbox web settings, try to save, verify the re-auth banner.
- **Edge cases that apply:**
  - Entry with custom fields containing protected values (KP2A passkey fields) — must round-trip through edit even though they're not directly editable in v1.
  - Entry with a TOTP secret — the TOTP setup form is in scope; verify the codes still generate after edit.
  - Very long notes (test with 64 KB of text) — form doesn't lock up.
  - User backgrounds the app mid-edit, returns later — draft is preserved (not lost on background); inactivity timer behavior matches the lock-during-edit rules.

## Exit criteria

- [ ] All new unit and UI tests pass.
- [ ] No force unwraps.
- [ ] All accessibility identifiers above are present; no existing identifiers were renamed (verify with the UI test suite passing without identifier changes).
- [ ] `xcodegen generate` run after the `project.yml` update.
- [ ] All affected folder-local `README.md` files are updated to reflect new/changed files, services, views, and flows introduced by this slice (e.g. `KeeForge/Views/README.md`, `KeeForge/Services/README.md`, `KeeForge/ViewModels/README.md`, `KeeForgeTests/README.md`, `KeeForgeUITests/README.md`).
- [ ] CHANGELOG entry added under `## Unreleased`.

## Open question for the implementer

Where exactly does the `database.save` button live? Two natural homes:
- On the `GroupListView`/`EntryListView` toolbar (one per database session).
- On a global toolbar at the database root that's always visible.

Pick whichever fits the existing toolbar structure best. The accessibility identifier `database.save` must end up on whichever button it lands on.

## CHANGELOG entry

`- Added: Create, edit, and delete entries from the main app, with strong password generation and unsaved-change protection.`
