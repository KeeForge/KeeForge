# Entry Views

**Scope:** entry detail, editor, history, attachments, icon picker, the entry lists, and the row-action state all three shells share. Folder-wide UI rules are in `../AGENTS.md`; read it first.

## Ownership

- `EntryEditViewModel` owns fields and payloads; `DatabaseEditorCoordinator` owns dirty registration, submission, completion, and Save and Lock (`../../ViewModels/AGENTS.md`). `EntryEditView` (iOS) forwards appearance, dirty, and conflict changes and turns completion into dismissal. Every presenter closes through `onComplete`. On Mac, `Mac/MacEntryEditorView` draws the window presentation's `MacEntryEditorSession` (`../../ViewModels/`) inline in the detail column; the session owns the coordinator, so the view only forwards dirty and conflict changes, and its completion closes the session.
- `RestoreRowAction` (iOS) shares entry/group recovery through `PendingMove.restoreOrChooseDestination`, which the Mac sidebar and entry list menus also call; `PendingMove.restore` hosts the fallback destination picker with a recovery title. Cancellation stages nothing.
- `PendingRowActions.swift` is the one source of delete-confirmation wording and move state for the iOS group list, `EntryListView`, and the macOS workspace. The Mac menu-bar Delete builds the same `PendingDeletion`; no path deletes without it.
- Entry-row context-menu gates and effects live in `EntryRowActions` (`../../ViewModels/`); `EntryRowCopyActions`, `EntryRowDuplicateAction`, `EntryRowMoveAction`, and `EntryRowSelectAction` are thin iOS SwiftUI items over it; the Mac entry table builds its AppKit menu from it directly. Add or change an item there, not per shell. They hand an editor or `PendingMove` back to the caller instead of presenting, because the host differs per shell.
- A duplicate saved from the search results or tag browser opens like a new entry: iOS pushes or selects it once its sheet has dismissed, macOS selects it in place.
- `EntryRowActions.canMove` (writable, not in the recycle bin) is the shared ordinary move/duplicate/select gate; Restore uses the session’s separate recovery eligibility. The group-row move keeps its own gate in `../Group/GroupListView.swift` on purpose.
- `EntryListView` is the iOS search results and tag browser list. On macOS every list (group, collection, tag, search) is the AppKit `MacEntryListViewController` (`../../../KeeForgeMac/App/`).

## Invariants

- `EntryDetailView` is iOS only. It shows entry actions and any sync warning in its toolbar; on iPhone it also offers Lock (`lock.button`) beside Edit; at regular width the sidebar's Lock sits beside it, so the detail adds none.
- The Mac detail is `Mac/MacEntryDetailView` on `MacEntryDetailModel` (`../../ViewModels/`): header (icon, title, path, Edit), cards of label/value rows, footer (dates, History link). It reads values, reveals and copies only through the model, never an `EncryptedValue`; the copy tick is `MacCopyFeedback`, whichever path copied. Edit (`entry-detail.edit`) sits in its header and opens the inline editor, which replaces the detail in the column until it closes. The icon picker is a sheet from the detail; the History link opens `Mac/MacEntryHistorySheet` on the presentation's `MacEntryHistorySession` (`../../ViewModels/`).
- On iOS the detail puts its fields in one `EntryFieldsCard` of label/value rows (`isCardRow` on the field rows).
- Below the fields, iOS gathers Group, Tags, Created, Expires and History in one card; the Group row pushes the group only in the compact stack. A row whose content switches with state (the password reveal) keeps one top-level container: in a `List` a changed top-level view is a new row, and its `onDisappear`/`onAppear` would clear and reload the reveal without end.
- Entry rows in `EntryListView` and the group list are buttons, not `NavigationLink`s, so they carry no chevron; they still push `DatabaseRoute.entry` in compact and select in the regular shells.

### Closing a deleted entry

- `EntryDetailView` closes itself through `finishClose()` when its entry leaves the index. It runs at most once: both `onAppear`s can fire on one reveal and each `dismiss()` pops a level.
- While its editor is up, the entry-unavailable branch does not close: the vanished entry is the editor's own permanent delete, and the editor's `.deleted` completion drives the close. On the iPad detail root that branch's `onAppear` fires even under the pushed editor.
- On iOS the close waits for the `onAppear` that follows the editor pop. Popping the editor and the detail in one transaction drops the second pop on iOS 26. On Mac the inline editor replaces the detail, which mounts again once the editor closes and clears a vanished entry then.
- The iPad detail column passes `popsOnClose: false` and clears the selection in `onClose`. Its `dismiss` has nothing of this screen to pop and would pop the sidebar's stack instead. `MacEntryDetailView` clears the selection itself, once, while the session is unlocked and no editor is open.
- A deletion handed to a container passes the finished `PendingDeletion`, never the entry, so the per-entry soft/permanent choice is not recomputed against the wrong group.

### List rendering

- On iOS, `EntrySelectionRow` and the selection controls (`EntrySelectionChrome` in iPhone's bars, `EntrySelectionBar` elsewhere) share the session's bulk selection across group, search, and tag lists. Selecting a row toggles it without opening it or offering context/swipe actions; each screen uses its existing move picker. Keep a concrete row container around the selection/browse branch so `List` defers offscreen rows.
- `EntryListView` keeps its selection/navigation branch inside a concrete row container so `List` can identify rows without constructing every match.

### Mac lists

- The Mac entry table's Return and double-click go through `DatabaseViewModel.requestEntryEdit()` so they open the window's one inline editor; while it is open they do nothing.

### Custom icons

- `CustomIconsView` is shared by the entry picker and Database Details → General. The session stages rename/delete edits and uses its ordinary save/conflict path. Rename cancellation stages nothing; deletion requires confirmation that live items and history fall back to defaults. Read-only sessions expose no mutations.
- Icon names are database content, not app preferences; naming upgrades KDBX 4.0 to 4.1 and the rename form explains this.

### Secrets, values, attachments

- A completed password reveal survives the editor for the same mounted entry: disappearance clears the plaintext, reappearance and a same-entry password edit refresh it without a new prompt. A session-key change conceals it; selecting another entry replaces the detail's identity.
- `EntryRowCopyActions` does not invalidate on disappearance, so a context-menu copy can finish after the menu closes. It still rejects a changed session, password, or entry.
- Attachment previews are plaintext temp files (`AttachmentPreviewFileStore`). On iOS cleanup runs from the Quick Look `onDismiss` and when the shown entry changes. On Mac every Quick Look and Share goes through the window's `MacAttachmentPreviewController` (`../../../KeeForgeMac/App/`) and its `AttachmentPreviewSession`, whose cleanup triggers are listed in `../../ViewModels/AGENTS.md`; a Mac view never writes or holds a preview file.
- Mac Large Type: the password row's button (`entry.password.large-type`) and View ▸ Show in Large Type both disclose through the reveal gate and hand the plaintext straight to the app's one `MacLargeTypePanelController` (`../../../KeeForgeMac/App/`), which hosts `Mac/MacLargeTypeView` (`large-type.panel` on the panel, `large-type.close`). No view keeps the password; the controller drops it on every close trigger it lists.
- iOS attachment rows are positional and carry `.id(attachment)`. Tests enumerate them by the `entry.attachment.<index>` prefix because SwiftUI collapses each row into one accessibility element; a shared row identifier would be shadowed. Mac rows keep `entry.attachment.<index>` on the clickable name; their buttons are `entry.attachment.quick-look.<index>` and `entry.attachment.share.<index>`.
- `EntryHistoryView` is iOS only. The Mac History sheet reads every value, reveal and copy through its session's `MacEntryDetailModel(.history)`: a version's protected values stay masked until the gated reveal, and the comparison shows only that one differs. Its copy ticks are the session's own, never the live detail's. The session closes on lock, a content change, another selection, a window reset and its own dismissal. Identifiers: `entry-history.current-version`, `entry-history.version.<position>`, `entry-history.difference.<field>`, `entry-history.password.reveal`, `entry-history.copy.<key>`, `entry-history.version-detail`, `entry-history.restore` (Restore…), `.restore.confirm`, `.done`.
- The Password Generator panel (`Mac/MacPasswordGeneratorPanelView`, `password-generator.panel`, Copy `password-generator.copy`) is hosted by `MacPasswordGeneratorPanelController` (`../../../KeeForgeMac/App/`), which owns its model and drops it on close.
- `entry-detail.title` (a leaf `Text`) is how the macOS tests read which entry the detail column shows. `entry-detail.history` carries the stored-version count as its accessibility value.

### Editor

- Custom field reordering uses a native List sheet containing field names only, plus named move controls in the iOS form; the Mac editor offers Reorder Fields… and keeps move up/down as VoiceOver actions on each row. Field values never appear in reorder rows. The view model owns order, including dirty tracking and save payloads.

- `EntryEditView` draws additional URL rows in Basics using `EntryEditViewModel.additionalURLs`, with a named remove action for VoiceOver. Field names are stored as `KP2A_URL_<n>` but are not shown to the user; `EntryDetailView` displays those URLs once, outside Custom Fields.
- On iOS the editor splits Basics into the fields, the URLs and the tags, and short fields are label/value rows (`basicFieldRow(_:inline:)`).
- `EntryEditView.body` is at the limit of what the CI Xcode type-checks. Put a new presentation in a `ViewModifier` (as `EntryAttachmentImporter` does), not inline, or the build fails only on CI.
- Every site that builds an `EntryEditViewModel` passes `knownTags` and the location's inherited tags. Both default to empty, so a missed site compiles and silently loses tag suggestions.
- Save and Save and Lock stay disabled while attachment files are being read, and while `canSave` is false; the lock prompt must never write an invalid form.
- Edit-mode reveals and turning off custom-field protection are gated by `secretAccess`; a create-mode value was typed this session and stays ungated. Turning protection on conceals any revealed value. On Mac these gates are `MacEntryEditorSession`'s, and closing or locking drops every reveal.

### Mac inline editor

- The editor follows the EditEntry, NewEntry and CodeSetup boards: a header with the title field, Cancel (Esc) and Save / Create, then cards. ⌘S is File ▸ Save, which saves the open editor through the presentation; Return stays in the fields. The title takes focus once, when the editor opens (`hasFocusedTitle`); a redraw never moves the window's first responder.
- The group is a pop-up only for a new entry; an edited entry shows its path and moves through Move to Group…. There is no Delete Entry, and Change Icon stays on the detail header.
- The Generate popover owns its own `PasswordGeneratorModel` and drops the suggestion when it closes. Set Up… opens `Mac/MacTOTPSetupSheet` on `applySetupInput` and keeps `entry-edit.totp.enter-link`; a configured code shows its live value, Advanced Options (`entry-edit.totp.advanced`) and a remove button. The Mac editor has no `entry-edit.totp.enter-key`, `entry-edit.delete`, `entry-edit.custom-field.move-up/down.N` or `entry-edit.totp.preview-copy`.
- Anything presented above the editor (popover, sheets, alerts, the file importer) is dismissed when a lock prompt arrives, so "Save your changes before locking?" is never hidden.

## Tests

- Search-results delete and move: `SearchResultsDeleteUITests` and `SearchResultsMoveUITests`, both in `KeeForgeUITests/EntryEditUITests.swift`. The move gate itself: `testEntryRowMove...` in `DatabaseViewModelTests`, the other row gates `testEntryRowActions...` there.
- Mac inline editor lifecycle and freeze: `MacWorkspacePresentationTests`, `MacEntryEditorSessionTests`, and the controller classes for the frozen sidebar, table and toolbar. Row menu: `EntryRowCopyUITests`, `EntryDuplicateUITests`. Editor: `EntryEditSmokeUITests`; its custom-field cases cover moving, protection toggles, and reopening, with counterparts in `MacSmokeUITests`. `ProtectedCustomFieldEditorAuthUITests` covers the reveal and protection-removal authentication gates. Tags shown on detail: `InheritedTagsUITests`.
- Attachments: `EntryAttachmentsSmokeUITests` and `EntryAttachmentFileLoaderTests` (size budget). The system file picker is exercised by hand. Mac Quick Look and Share: `MacAttachmentPreviewControllerTests` (panel control, data source, share picker completion, every close trigger, responder-chain placement); the system panel and picker themselves are checked by hand. Large Type: `MacLargeTypePanelControllerTests` (content, every close trigger, plaintext released, sharing type at creation, never shown) and `DatabaseWindowControllerTests` (the menu command through the gate).
- History: `EntryHistoryUITests` on iOS. Mac: `MacEntryHistorySessionTests` (comparison, gating, separate ticks, every close trigger, restore) and `EntryVersionComparisonTests`; the sheet is captured as `08b-entry-history` in `MacScreenshotAuditUITests`. Generator panel: `MacPasswordGeneratorPanelControllerTests`, menu item in `MacMainMenuTests`.
- Editor saves keep passkey data and unknown XML the Mac editor does not show: `MacEntryEditorSessionTests`.
- Held completion behind a save conflict: `SaveConflictMergeUITests`.

## See also

- `../AGENTS.md`: presentation hosts, the one-alert rule, identifiers, Mac form modifiers
- `../../ViewModels/AGENTS.md`: editor coordinator, `EntrySecretAction`, `AttachmentLoadCoordinator`, tag commit rules
- `../Group/AGENTS.md`, `../SearchAndTags/AGENTS.md`: the containers that host these lists
