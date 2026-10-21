# Group Views

**Scope:** post-unlock browsing on iOS and iPadOS (`GroupListView`), the group editor, and the group icon and move-destination pickers. Folder-wide UI rules are in `../AGENTS.md`; read it first.

## Ownership

- `GroupListView` is iOS/iPadOS only. macOS browses through `macSplitView` and `MacGroupTreeRow` in `../../App/RegularDatabaseWorkspaceView.swift`, which carries its own move sheet, delete confirmation, group-row menu, and Database Details button. A feature added here needs its Mac counterpart there.
- On the iPad split view, New Entry and Edit Group are handed to the workspace through `onCreateEntry` / `onEditGroup` so they open in the detail column. With the closures nil (compact) `GroupListView` pushes them itself.
- `GroupEditView` only collects fields; `DatabaseEditorCoordinator` applies them as one `updateGroup` edit and owns dirty state, Save and Lock, and completion (`../../ViewModels/AGENTS.md`). The Mac sidebar raises the group to the workspace so the sheet is hosted on the split view, not on a row that comes and goes.
- Recycled group rows expose the shared Restore action on iOS/iPadOS and in the Mac sidebar. The Recycle Bin itself is excluded.
- The pickers (`GroupIconPickerView`, `MoveToGroupPickerView`) report a pick and dismiss. The caller mutates and saves; cancelling writes nothing.
- `DatabaseViewModel.workspace.viewMode` decides what the database root lists. The last browsing view picked is stored in `UserDefaults`, so lock and relaunch return to it; the Recycle Bin is never stored.

## Invariants

- Group rows keep navigating while entry bulk selection is active. The root list hosts one selection bar for its own rows and inline search results; a picked destination moves the selected entries through one save.
- Edit Group, Change Icon, and the AutoFill exclusion toggle have the same eligibility (not read-only, not the recycle bin, not inside it), spelled as `canEditGroup`, `canChangeGroupIcon`, and `canChangeAutoFillExclusion`. Change them together.
- The excluded badge is hidden inside the recycle bin so a row never shows a badge it cannot act on; KeePass marks the bins it creates `EnableSearching` false.
- The recycle bin is never drawn as a group row at any level; it opens only from the view menu.
- Cloud browsing pins its title beside Sync Now above the list, with the root title as the view menu. Local databases draw the view menu three ways: a list section header from iOS 26 (the bar's large title takes no taps), the inline bar title once that header scrolls away, and a toolbar button on iOS 18 to 25 (`hasTitleViewMenu`). Change all title-menu variants together.
- View-menu items are `Toggle`s, not a `Picker`, because a picker's options cannot be split into menu sections.
- While the title header is on screen the bar's title place holds the app's name and the bar has no title menu; once the header scrolls away the inline title takes its place with `ToolbarTitleMenu`. Never both: a title menu with no title to hang on, or a leading item that does not fit beside the actions, turns into a "…" overflow button on iOS 27, a second view switcher (`ViewMenuLargeTextUITests`). The app name leaves the bar with the header, so whether it has slid in is stored on `GroupListView`, not in the item.
- `databaseActionsPlacement` pins the trailing items where the SDK allows, or an iOS 27 build folds Lock into an overflow menu behind a long inline title.
- `GroupListView.entryRow(for:)` keeps its row-kind branch (verification code, selection, navigation) inside a concrete row container so `List` builds only the rows it shows. Wrapped in a `Group`, every entry of the group or view is constructed up front.
- `VerificationCodeRow` is two sibling buttons; the opening one keeps `entry.navlink` and does what the link would in each shell (select in the regular workspace, append to `workspace.navigationPath` in compact).
- The group editor never previews a custom icon: the payload carries only a standard `iconID`, and the draft leaves a custom icon alone unless a different standard one is picked.
- The group editor's tag row mirrors the entry editor's, with one intended difference: suggestions do not exclude inherited tags, because restating an ancestor's tag on a child group is legitimate.
- `MoveToGroupPickerView` is also the New Entry destination picker, with its own title. Options are resolved when the sheet is built, not when the menu was tapped.

## Tests

- `ViewMenuUITests`, `DefaultViewUITests`, `ViewMenuLargeTextUITests`, `TagBrowserUITests` for the root views; `GroupEditUITests`, `GroupIconPickerUITests` for the editor and picker.
- `KeeForgeUITestCase.selectDatabaseView` is the supported way to switch views in a test.
- Cloud title-menu placement, scrolling with Sync Now visible, and the status popover: `CloudUnlockSmokeUITests`.
- Row laziness of the group, All Entries, Verification Codes, and Recycle Bin lists: `testBrowseListsDoNotResolveOffscreenRows` in `DatabaseViewModelTests` (iOS only).

## See also

- `../AGENTS.md`, `../Entry/AGENTS.md` (shared row actions and `PendingRowActions`), `../SearchAndTags/AGENTS.md`
- `../../App/AGENTS.md`: the macOS workspace
