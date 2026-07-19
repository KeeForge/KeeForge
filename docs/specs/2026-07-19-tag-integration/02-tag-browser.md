# Slice 02: Tag Browser

> Parent: [`epic.md`](./epic.md) · Depends on: 01

## Goal

Deliver the browsing surface issue #11 asks for: from the database root, reach the list of
all tags and drill into any tag's entries, on iPhone, iPad, and macOS.

## Scope

**In:**

- **iPhone/iPad (stack shells):** a root-level "Tags" row in `GroupListView` — visible only
  when showing the database root group — with the database's distinct-tag count. Tapping
  pushes the tag list screen. Both stack shells (`DatabaseNavigationView` and the iPad
  sidebar in `RegularDatabaseWorkspaceView`) get this for free since they share
  `GroupListView`.
- **Tag list screen:** every distinct tag from slice 01's index with its entry count,
  sorted case-insensitively locale-aware (Finder-style). Tapping a tag pushes its entry
  list. Empty state when the database has no tags that teaches the feature (how to add a
  tag), since discoverability is the issue's core complaint — the "Tags" row stays visible
  at zero.
- **Tag-filtered entry list:** reuse `EntryListView` semantics (rows, sort order, entry
  navigation) for the entries carrying the tapped tag. Entries must be derived from the
  view model at render time — not a snapshot captured at navigation time — so edits, deletes,
  and recycling reflect immediately. If the tag ceases to exist while displayed, the screen
  shows an empty state; it must not crash or pop unexpectedly.
- **Navigation plumbing:** a new dedicated Hashable tag-destination type registered with
  `navigationDestination` in both stack shells (today only `UUID` groups and `KPEntry` are
  registered; a bare `String` destination is forbidden per the epic). Lock/close already
  resets `navigationPath`; verify tag destinations clear with it.
- **macOS (split-view shell):** a "Tags" section in the sidebar column of `macSplitView`
  beneath the group tree, listing tags with counts; selecting one shows the filtered entry
  list in the content column, KeePassXC-style. Sidebar tag selection must clear on lock,
  close, and database switch, like group selection.
- **Entry-detail chips:** the existing tag capsules in `EntryDetailView` become tappable,
  navigating to that tag's filtered list (from any context, including when already inside a
  tag-filtered list — nested pushes are fine). Chips gain accessibility identifiers; the
  section previously had none.

**Out:**

- Group-tag inheritance: this slice browses entries' own tags; slice 03 widens the same
  screens to effective tags with no UI rework (the browser must not assume its data source
  is entry-own tags anywhere).
- Editor tag suggestions (slice 04) or any write operation.
- Tag chips or counts anywhere else (list rows, search results).
- A Strongbox-style "popular tags" cloud on the root screen — considered and rejected by the
  maintainer to keep the root list calm.

## Implementation requirements

- All tag data comes from slice 01's index; this slice adds no filtering/counting logic of
  its own beyond presentation sorting.
- Recycled entries never appear in tag-filtered lists (the index already excludes them);
  consequently a tag whose last live carrier was recycled disappears from the list — the
  browser must tolerate this at any moment (see empty-state requirement).
- Tag names are arbitrary user text (spaces, emoji, RTL, very long). Rows truncate rather
  than wrap navigation chrome; the tag name is the navigation title of its entry list, using
  the standard truncation behavior.
- Sorting uses the platform's locale-aware Finder-style comparison so `tag2` sorts before
  `tag10` and case variants sit adjacent. Ties (case-variant tags) keep a stable, documented
  order (e.g. case-sensitive as final tiebreak).
- The read-only database mode changes nothing here — browsing is read-only by nature. Cloud
  and local databases behave identically.
- All user-facing strings (row title, counts if worded, empty-state copy, section headers)
  are localized in `en` and `de`; counts use proper pluralization via the string catalog,
  not manual `"%d items"` concatenation.
- Follow the shells' existing patterns; do not restructure `RegularDatabaseWorkspaceView`
  beyond adding the section and selection handling.

## Affected areas

- New: tag list screen (and, if the implementer prefers, a small tag-entry-list wrapper
  view) under `KeeForge/Views`; the tag navigation-destination type.
- Modified: `KeeForge/Views/GroupListView.swift` (root Tags row),
  `KeeForge/Views/EntryDetailView.swift` (tappable chips + identifiers),
  `KeeForge/App/KeeForgeApp.swift` and `KeeForge/App/RegularDatabaseWorkspaceView.swift`
  (destination registration; macOS sidebar section + selection reset),
  `KeeForge/ViewModels/DatabaseViewModel.swift` (navigation/selection state only),
  `KeeForge/Resources/Localizable.xcstrings` (both locales).

## KeeForge bits

- **Targets:** all new/changed files are `KeeForge` app target only; nothing is shared with
  the AutoFill targets.
- **project.yml:** add the new view file(s) to the `KeeForge` target; run
  `xcodegen generate`.
- **Accessibility identifiers:** new — the root Tags row, the tag list and its rows, the
  tag-filtered entry list container, and the entry-detail tag chips. Dynamic rows follow the
  existing dot-namespaced convention (like `entry-edit.tags-field`) with a stable per-tag
  suffix. Existing identifiers in `GroupListView`, `EntryDetailView`, and `EntryListView`
  are preserved.
- **CHANGELOG entry:** see below; replaces slice 01's, replaced by slice 03's.

## Testing

- **Unit:** `DatabaseViewModelTests.swift` — named scenarios: display sort order for a mixed
  case/numeric/unicode tag set (Finder-style expectations, stable tiebreak); tag
  navigation/selection state clears on lock and on database close; filtered-entry
  derivation reflects an edit that removes the last carrier of a tag (empty result, no
  crash).
  Run slice: `-only-testing:KeeForgeTests/DatabaseViewModelTests -only-testing:KeeForgeTests/LocalizationTests`
- **Integration / UI:** one XCUITest happy path on iPhone: open fixture database → root
  shows Tags row → tag list shows a known tag with count → tap → entry appears → tap entry →
  detail shows the tag chip. Use the new accessibility identifiers; follow
  `KeeForgeUITests/README.md` flake guidance. (A tagged-entry fixture may need to be added
  or an existing fixture extended — document credentials in `TestFixtures/README.md` and
  wire resources through `project.yml` if so.)
- **Manual:** iPhone drill-down; iPad sidebar drill-down; macOS sidebar tag selection →
  entry list → entry; lock while a tag list is showing and confirm unlock lands in a clean
  state; delete the last entry carrying a tag while its list is open.
- **Edge cases that apply:** zero-tag database (teaching empty state), tag vanishing while
  displayed, locked DB mid-flow (path + macOS selection reset), long/emoji/RTL tag names,
  case-variant tags listed separately but adjacent, large tag sets (list stays scrollable
  and responsive; no per-render index rebuilds).

## Exit criteria

- [ ] Unit tests and the UI happy path above pass; `LocalizationTests` green in `en`/`de`.
- [ ] Manual checks done on all three form factors.
- [ ] Accessibility identifiers added; existing ones untouched.
- [ ] No force unwraps; no secrets touched; no work added to render paths beyond display
      sorting.
- [ ] `project.yml` updated and `xcodegen generate` run.
- [ ] CHANGELOG entry replaces slice 01's.

## CHANGELOG entry

`- Added a tag browser: browse all tags with entry counts from the database root (and the macOS sidebar), and jump to a tag from any entry's detail screen. Search matches tags.`

(Replaced by slice 03's entry when it lands.)
