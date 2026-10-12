# Entry Views

**Scope:** entry detail, editor, history, attachments, icon picker, the entry lists, and the row-action state all three shells share. Folder-wide UI rules are in `../AGENTS.md`; read it first.

## Ownership

- `EntryEditViewModel` owns fields and payloads; `DatabaseEditorCoordinator` owns dirty registration, submission, completion, and Save and Lock (`../../ViewModels/AGENTS.md`). `EntryEditView` forwards appearance, dirty, and conflict changes and turns completion into dismissal. Every presenter closes through `onComplete`.
- `PendingRowActions.swift` is the one source of delete-confirmation wording and move state for the iOS group list, `EntryListView`, `MacEntriesList`, and the macOS workspace. The Mac menu-bar Delete builds the same `PendingDeletion`; no path deletes without it.
- Entry-row context-menu items are the shared `EntryRowCopyActions`, `EntryRowDuplicateAction`, and `EntryRowMoveAction`. Add or change an item there, not per shell. They hand an editor or `PendingMove` back to the caller instead of presenting, because the host differs per shell.
- `EntryRowMoveAction.isAvailable` (writable, not in the recycle bin) is the single "is this entry editable from a row" gate; Duplicate reuses it. The group-row move keeps its own gate in `../Group/GroupListView.swift` on purpose.
- Three entry lists: `EntryListView` (iOS search results and tag browser), `MacEntriesList` (the same two on macOS), and `MacEntriesColumn` in `../../App/RegularDatabaseWorkspaceView.swift` (the Mac group column). The Mac two share `MacEntryRow`.

## Invariants

- `EntryDetailView` shows entry actions and any sync warning in its toolbar. Lock stays on the compact list or regular-width workspace toolbar, leaving room for the entry title; the list's `lock.button` remains the manual-lock path.

### Closing a deleted entry

- `EntryDetailView` closes itself through `finishClose()` when its entry leaves the index. It runs at most once: both `onAppear`s can fire on one reveal and each `dismiss()` pops a level.
- While its editor is up, the entry-unavailable branch does not close: the vanished entry is the editor's own permanent delete, and the editor's `.deleted` completion drives the close. On the iPad detail root that branch's `onAppear` fires even under the pushed editor.
- On iOS the close waits for the `onAppear` that follows the editor pop. Popping the editor and the detail in one transaction drops the second pop on iOS 26. A macOS sheet never re-fires the presenter's `onAppear`, so it closes directly.
- Selection-driven shells (iPad detail column, macOS) pass `popsOnClose: false` and clear the selection in `onClose`. Their `dismiss` has nothing of this screen to pop and would pop the sidebar's stack instead.
- A deletion handed to a container passes the finished `PendingDeletion`, never the entry, so the per-entry soft/permanent choice is not recomputed against the wrong group.

### List rendering

- `EntryListView` keeps its selection/navigation branch inside a concrete row container so `List` can identify rows without constructing every match.

### Mac lists

- `MacEntryRow` sets the selection in its tap handler, and the double-click is a `simultaneousGesture` attached after that tap. Two plain tap gestures compose exclusively and hold every single click for the system double-click interval before the detail pane updates.
- Return and double-click go through `DatabaseViewModel.requestEntryEdit()` so they open the one editor the workspace hosts, not a second sheet.
- The Mac history browser exists because pushing inside that sheet loses its toolbar. Its `init`-seeded selection and `.id(selection)` list are both load-bearing; the reasons are at the sites in `EntryHistoryView.swift`.

### Secrets, values, attachments

- A completed password reveal survives the editor for the same mounted entry: disappearance clears the plaintext, reappearance and a same-entry password edit refresh it without a new prompt. A session-key change conceals it; selecting another entry replaces the detail's identity.
- `EntryRowCopyActions` does not invalidate on disappearance, so a context-menu copy can finish after the menu closes. It still rejects a changed session, password, or entry.
- Attachment previews are plaintext temp files (`AttachmentPreviewFileStore`). Cleanup runs from the Quick Look `onDismiss` on both platforms and when the shown entry changes; keep both when touching the preview flow.
- Attachment rows are positional and carry `.id(attachment)`. Tests enumerate them by the `entry.attachment.<index>` prefix because SwiftUI collapses each row into one accessibility element; a shared row identifier would be shadowed.
- `entry-detail.title` (a leaf `Text`) is how the macOS tests read which entry the detail column shows. `entry-detail.history` carries the stored-version count as its accessibility value.

### Editor

- `EntryEditView.body` is at the limit of what the CI Xcode type-checks. Put a new presentation in a `ViewModifier` (as `EntryAttachmentImporter` does), not inline, or the build fails only on CI.
- Every site that builds an `EntryEditViewModel` passes `knownTags` and the location's inherited tags. Both default to empty, so a missed site compiles and silently loses tag suggestions.
- Save and Save and Lock stay disabled while attachment files are being read, and while `canSave` is false; the lock prompt must never write an invalid form.
- Edit-mode reveals are gated by `secretAccess`; a create-mode value was typed this session and stays ungated.

## Tests

- Search-results delete and move: `SearchResultsDeleteUITests` and `SearchResultsMoveUITests`, both in `KeeForgeUITests/EntryEditUITests.swift`. The move gate itself: `testEntryRowMove...` in `DatabaseViewModelTests`.
- Row menu: `EntryRowCopyUITests`, `EntryDuplicateUITests`. Editor: `EntryEditSmokeUITests`. Tags shown on detail: `InheritedTagsUITests`.
- Attachments: `EntryAttachmentsSmokeUITests` and `EntryAttachmentFileLoaderTests` (size budget). The system file picker is exercised by hand.
- History: `EntryHistoryUITests` on iOS. The Mac shell is only captured, as `08b-entry-history` in `MacScreenshotAuditUITests`.
- Held completion behind a save conflict: `SaveConflictMergeUITests`.

## See also

- `../AGENTS.md`: presentation hosts, the one-alert rule, identifiers, Mac form modifiers
- `../../ViewModels/AGENTS.md`: editor coordinator, `EntrySecretAction`, `AttachmentLoadCoordinator`, tag commit rules
- `../Group/AGENTS.md`, `../SearchAndTags/AGENTS.md`: the containers that host these lists
