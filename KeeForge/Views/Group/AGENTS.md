# Group Views

**Scope:** post-unlock browsing on iOS and iPadOS (`GroupListView`), the group editor, and the group icon and move-destination pickers. Folder-wide UI rules are in `../AGENTS.md`; read it first.

## Ownership

- `GroupListView` is iOS/iPadOS only. macOS browses through the native split controller and SwiftUI columns, with sheets and confirmations on the stable workspace presentation host. A feature added here needs its Mac counterpart there.
- New Entry, Duplicate, and Edit Group open through `viewModel.workspace.present(_:)`; the shell presents the editor (`../../App/AGENTS.md`, Layout changes). On iPhone a created entry replaces its editor on the stack in one path change (`finishCompactEntryEditor`).
- `GroupEditView` only collects fields; `DatabaseEditorCoordinator` applies them as one `updateGroup` edit and owns dirty state, Save and Lock, and completion (`../../ViewModels/AGENTS.md`). The Mac sidebar raises the group to the workspace so the sheet is hosted on the split view, not on a row that comes and goes.
- Recycled group rows expose the shared Restore action on iOS/iPadOS and in the Mac sidebar. The Recycle Bin itself is excluded.
- The pickers (`GroupIconPickerView`, `MoveToGroupPickerView`) report a pick and dismiss. The caller mutates and saves; cancelling writes nothing.
- The database root lists its sync status (iPhone, cloud only), the tiles, and the root group's contents. Each tile pushes `DatabaseRoute.collection`, a `GroupListView` with `collection` set. The iPad sidebar keeps its own stack, so it passes `onOpenRoute`; compact appends to `workspace.navigationPath`.

## Invariants

- After creating an entry, compact opens its detail from the list’s next `onAppear`, after the editor has popped. Never pop the editor and push the detail in the same transaction.
- Group rows keep navigating while entry bulk selection is active. The root list hosts one selection control set for its own rows and inline search results; a picked destination moves the selected entries through one save.
- From iOS 26 on iPhone, selection mode lives in the bars like Notes (`EntrySelectionChrome`): Select All and Done replace the back button and the trailing actions, Move to Group and Delete (to the recycle bin, one save, `recycleEntries`) sit in the bottom bar, the count is the title, and search and New are hidden. Select All covers the movable entries this screen lists, not search results. iPad and earlier releases keep `EntrySelectionBar`; macOS has the entry list's native bar.
- On iPhone the root's title uses `.toolbarTitleDisplayMode(.inlineLarge)` (`GroupListLeadingTitle`), so it sits level with Lock, Sort, and More rather than under them. A custom leading toolbar item does not work: the bar keeps that item at its first, tiny width.
- Edit Group, Change Icon, and the AutoFill exclusion toggle have the same eligibility (not read-only, not the recycle bin, not inside it), spelled as `canEditGroup`, `canChangeGroupIcon`, and `canChangeAutoFillExclusion`. Change them together.
- The excluded badge is hidden inside the recycle bin so a row never shows a badge it cannot act on; KeePass marks the bins it creates `EnableSearching` false.
- The recycle bin is never drawn as a group row at any level; it opens only from its tile.
- The iPad sidebar pins a cloud database's title above Sync Now, because the sidebar has no toolbar to hold it (`pinsCloudTitle`). On iPhone the root shows the sync state in words as its first row (`CloudSyncStatusRow`) while it syncs or has something to say.
- From iOS 26 compact screens put search and New in a bottom bar; iPad and earlier releases keep New in the top bar. The identifier `entry-list.add-entry` stays on New in both places.
- `databaseActionsPlacement` pins the trailing items where the SDK allows, or an iOS 27 build folds Lock into an overflow menu behind a long inline title.
- `GroupListView.entryRow(for:)` keeps its row-kind branch (verification code, selection, navigation) inside a concrete row container so `List` builds only the rows it shows. Wrapped in a `Group`, every entry of the group or view is constructed up front.
- `VerificationCodeRow` is two sibling buttons; the opening one keeps `entry.navlink` and does what the link would in each shell (select in the regular workspace, append to `workspace.navigationPath` in compact).
- The group editor never previews a custom icon: the payload carries only a standard `iconID`, and the draft leaves a custom icon alone unless a different standard one is picked.
- The group editor's tag row mirrors the entry editor's, with one intended difference: suggestions do not exclude inherited tags, because restating an ancestor's tag on a child group is legitimate.
- `MoveToGroupPickerView` is also the New Entry destination picker, with its own title. Options are resolved when the sheet is built, not when the menu was tapped.

## Tests

- New-entry detail after save: `EntryCreateFocusUITests` on iPhone and iPad; the Mac selection and inline-editor case is `MacSmokeUITests.testNewEntryIsSelectedAfterSaving`.
- `VaultHomeUITests`, `VaultLargeTextUITests`, `TagBrowserUITests` for the root and its collections; `GroupEditUITests`, `GroupIconPickerUITests` for the editor and picker.
- `KeeForgeUITestCase.selectDatabaseView` is the supported way to open a collection, or return to the root, in a test.
- The iPad cloud title, the iPhone sync warning and its Sync Now, pull to refresh, and the status popover: `CloudUnlockSmokeUITests`.
- Row laziness of the group, All Entries, Verification Codes, and Recycle Bin lists: `testBrowseListsDoNotResolveOffscreenRows` in `DatabaseViewModelTests` (iOS only).

## See also

- `../AGENTS.md`, `../Entry/AGENTS.md` (shared row actions and `PendingRowActions`), `../SearchAndTags/AGENTS.md`
- `../../App/AGENTS.md`: the macOS workspace
