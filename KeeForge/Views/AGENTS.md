# Views

**Scope:** SwiftUI screens for all three shells: compact iPhone, regular-width iPad, and the macOS app (`KeeForgeMac` compiles this whole folder). This file holds the rules every subfolder shares; each subfolder's `AGENTS.md` adds only what is specific to it.

## Ownership

Views compose state, collect input, and forward intent and lifecycle events. Workflow policy (unlock/lock, draft/save/conflict, editor completion, settings effects, routing) is owned in `../ViewModels/AGENTS.md`; never repeat it in a view. When a view starts needing real async or state logic, move it to `../ViewModels` or a helper type.

- All three shells are first-class. A change to navigation, chrome, editing, or status UI has to be checked in each; prefer sharing the row/detail/editor view over forking per shell.
- Compact pushes one session from the database list. iPad keeps the list visible and renders the session in a detail workspace. macOS always uses the regular layout (`usesRegularLayout` is hardcoded there).
- macOS never mounts `Group/GroupListView.swift` or the compact stack: it browses through `macSplitView` in `../App/RegularDatabaseWorkspaceView.swift`. Anything wired only into `GroupListView` is invisible on macOS and needs a counterpart there.
- `EntryEditView` and `GroupEditView` carry no `NavigationStack`. The presenter supplies one: a push on iOS, a sheet on macOS, where pushes inside split-view columns misrender.

## Invariants

### macOS forms and controls

- Any `Form` shown in a macOS sheet takes `.macGroupedForm()`. The default `.columns` style does not scroll, so a form taller than its sheet clips rows where no click can reach them. Find the current ones with `grep -rl macGroupedForm KeeForge AutoFillExtension`.
- In a grouped form, text fields take `.macFormFieldStyle()` (grouped draws them borderless), and `.macLabelsHidden()` wherever a caption or section header already names the field (macOS otherwise reserves a second label column).
- A `Button` whose label fills a row takes `.macPlainRowButton()`, or macOS draws a bordered slab inside the section card.
- Icon-only controls carry an `accessibilityLabel` and `.macHelp(...)` with the same text. Not `.help()`: on iOS that becomes the VoiceOver hint and changes what a labelled control reads out.
- Inside a button or link label use `Color.primary`, not `.primary`/`.secondary`: the hierarchical styles resolve against the tint there.

All of these shims live in `../Extensions/PlatformCompat.swift`.

### Presentation hosts

- Attach `sheet`, `alert`, `confirmationDialog`, and `navigationDestination` hosts to the body's outer container, never inside an `if let` or empty-state branch. An update that flips the branch (deleting the last row, a permanent delete from a pushed editor) tears the host down and strands what it presented.
- Two sibling `.alert(item:)` on one presentation context collide and SwiftUI silently drops one. A list rendered inline in a container that already hosts a `PendingDeletion` raises its confirmation through `onRequestDeletion` (`ListScopedDeletionAlert` in `Entry/PendingRowActions.swift`); the macOS workspace uses a `confirmationDialog` for the same reason.
- A deleted entry's `EntryDetailView` closes itself; nothing else clears `selectedEntryID` for a permanent delete. Clearing it in the deleting update unmounts the detail column under a pushed editor, which then cannot pop. Mechanics in `Entry/AGENTS.md`.
- Both editors dismiss everything they present when a lock request arrives, because anything above the editor swallows the Save and Lock prompt. A new sheet, dialog, or importer on an editor joins that reset (the `pendingEditorLockRequest` `onChange` in each editor).
- A `confirmationDialog` goes on the control that raised it, not the form or list, so iPad anchors the popover there. Exception: a row that can scroll away or be filtered out must not host one.
- Present one thing at a time: a presentation started while an alert or swipe cell is still dismissing is dropped silently (see the deferrals in `DatabaseList/DatabaseListView.swift`). One view takes one `.fileImporter`; a second does not present reliably.

### Lists and rows

- A `ForEach` with `.onMove` produces one concrete row type. An `if`/`else` in its body gives the list two types to reconcile and a drag reorder repaints the old order; move the branch into a `ViewModifier` (`DatabaseRowChrome`).
- A `List` row holds at most one `NavigationLink`. With several, the row owns the link and a tap opens the wrong destination; a `Button` nested in a link's label gets no taps. Use sibling `Button`s that select or append to `workspace.navigationPath` (tag chips, `VerificationCodeRow`).
- Entry rows render `DatabaseViewModel.entry(withID:)`, not the entry they were handed. `KPEntry` compares equal by ID, so a caller's array looks unchanged after an edit and the row would show the pre-edit entry.
- On macOS, a tap gesture on a `List(selection:)` row consumes the click the list selects with, so the row sets the selection itself. Details in `Entry/AGENTS.md`.

### Secrets on screen

- Every reveal and authenticated copy goes through `EntrySecretAction` and the session's `secretAccess` gate. Controls invalidate it on disappearance and when their source value or session key changes.
- No `.textSelection(.enabled)` on a revealed secret: the system copy path bypasses `ClipboardService` (no expiry, no concealed type, no clear on lock). `CopyButton` is the only copy path.
- Displayed and copied field values pass through `DatabaseViewModel.resolvingFieldReferences(_:)` so `{REF:...}` shows as its target. Editors seed from the raw entry so a save keeps the reference.

### Accessibility identifiers

- `KeeForgeUITests` and `KeeForgeMacUITests` share one identifier surface. Keep identifiers stable or update both suites in the same change, including identifiers no test references yet. A new flow adds identifiers with the feature instead of leaving tests to match visible labels.
- Identifier stability is not element-type stability. macOS vault rows are `List(selection:)` cells, so `group.navlink` / `entry.navlink` are not buttons there: Mac tests query with `descendants(matching: .any)` (`MacUITestCase.rowQuery`), never `app.buttons`.
- An identifier on a container replaces the identifiers of the controls inside it. Put it on a leaf, or declare the container `.accessibilityElement(children: .contain)` (the tag strips do). This is why the tip cards and the quick-search root carry none.
- iOS 27 drops identifiers from buttons inside a `Section` of a SwiftUI `Menu` (labels survive). Tests reach those items with `KeeForgeUITestCase.menuButton(identifier:label:)`; keep both the identifier and a stable label.
- Expose a count or state a test reads as the element's accessibility value, not inside a locale-formatted label.

## Tests

- View behavior belongs in view-model unit tests where possible. For navigation, split-view, or sheet changes run the smallest affected class from `../../KeeForgeUITests/AGENTS.md`.
- macOS: read the row for your change in `../../AGENTS.md` ("macOS Test Strategy"). Selection and keyboard behavior of the Mac lists: `MacListKeyboardNavigationUITests`.

## See also

- `../ViewModels/AGENTS.md`: workflow owners the views forward to
- `../App/AGENTS.md`: the shells and the macOS workspace
- `../Extensions/AGENTS.md`: `PlatformCompat` shims
- `../../KeeForgeUITests/AGENTS.md`, `../../KeeForgeMacUITests/AGENTS.md`
