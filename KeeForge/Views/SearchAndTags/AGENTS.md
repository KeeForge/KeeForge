# SearchAndTags Views

**Scope:** search results, the tag browser, and the content of the macOS menu-bar quick-search panel. Folder-wide UI rules are in `../AGENTS.md`.

## Ownership

- `SearchView` and `TagEntriesView` compile only on iOS and render `../Entry/EntryListView.swift`. On macOS search results and the tag browser are modes of the AppKit entry list (`../../../KeeForgeMac/App/MacEntryListViewController.swift`, over `MacEntryListSnapshot`).
- Search never has a screen of its own: it is a branch of `GroupListView` on iOS and a mode of the entry list on macOS. The tag browser is a pushed screen on iOS and an entry-list mode on macOS.
- `TagListRows` is drawn inside `GroupListView`'s own `List` on iOS; macOS lists tags in its AppKit sidebar (`MacSidebarSnapshot`). `TagAccessibility` is the shared per-tag identifier suffix for every tag control in the app.
- `MacQuickSearchView` renders over `MacQuickSearchViewModel`. Arrow keys and Return are handled by the panel's key monitor in `../../Services/AppSupport/MacQuickAccessController.swift`, so the field keeps focus while the selection moves.

## Invariants

- Search results and tag entries share the session's bulk selection. An inline list leaves the selection bar to its host; a pushed tag list hosts its own bar. The Mac entry list shows its own native bar.
- Wherever one of these screens renders inline, it passes `onRequestDeletion` through to its list so the confirmation is raised to the container's host (the one-alert rule in `../AGENTS.md`). Where it is pushed (the iOS tag browser), the closure stays nil and the list hosts its own alert.
- `TagEntriesView` derives its entries from the view model on every render, never from a push-time snapshot. A tag whose last carrier is edited away shows the empty state instead of crashing or popping.
- Tag chips on entry detail are `Button`s in every shell, never `NavigationLink`s (the one-link-per-row rule in `../AGENTS.md`). `TagBrowserUITests` asserts which tag opens.
- Container and row identifiers (`search.results`, `tag-entries.list`, `search.entry.navlink`, `search.no-results`, `search.results.count`) are the same on both platforms although the lists differ.
- Case-variant tags (`Work`, `work`) share one identifier suffix. A test that must tell them apart enumerates matches instead of taking `firstMatch`.
- `quick-search.panel` is set on the panel window, not on this view's root, where it would replace every inner identifier.
- On macOS the database window's observer sets the search or tag context as its subtitle; the window title belongs to the database. Column hosts do not bridge titles or toolbars.

## Tests

- `TagBrowserUITests`, `InheritedTagsUITests`; search-results row actions in `SearchResultsDeleteUITests` / `SearchResultsMoveUITests` (`EntryEditUITests.swift`).
- `MacQuickSearchViewModelTests`; the Mac entry list's search and tag modes in `MacEntryListModelTests` and `MacEntryListViewControllerTests`, real keyboard selection in `MacListKeyboardNavigationUITests`.

## See also

- `../AGENTS.md`, `../Entry/AGENTS.md`, `../Group/AGENTS.md`
- `../../ViewModels/AGENTS.md`: search corpus, tag index, `DatabaseRoute`
