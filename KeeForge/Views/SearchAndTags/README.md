# SearchAndTags Views

Search results and the tag browser.

## Screen Map

- `TagListView.swift` and `TagEntriesView.swift` own the tag browser. `TagListView.swift` also declares `TagDestination` — the `Hashable` navigation value both stack shells register (`UUID` already means "group" and `KPEntry` "entry") — and `TagAccessibility`, the shared per-tag identifier-suffix normalizer. Entry points: the root-only "Tags" row in `GroupListView.swift` (`group-list.tags-row`, in-file `TagBrowserRow`, visible even at zero tags), the macOS sidebar's Tags section in `../../App/RegularDatabaseWorkspaceView.swift` (`MacTagRow`, selection through `DatabaseViewModel.selectedTag`), and the entry-detail tag chips. Those chips are `Button`s in every shell, never `NavigationLink`s: several `NavigationLink`s in one `List` row let the row own the link, so a tap opens the wrong tag or several at once and the whole row highlights (`TagBrowserUITests` asserts which tag opens); the compact shell appends to `DatabaseViewModel.navigationPath`. `TagEntriesView` re-derives its entries from the view model on every render, never from a push-time snapshot, so a tag whose last carrier is edited away shows its empty state instead of crashing or popping; it wraps `EntryListView`, so rows keep `search.entry.navlink`. Identifiers: `tag-list`, `tag-list.row.<normalized-tag>` (iOS list and macOS sidebar alike), `tag-entries.list`, `entry-detail.tag.<normalized-tag>`, `entry-detail.inherited-tag.<normalized-tag>`. macOS renders the tag name as a `navigationSubtitle` where iOS uses the navigation title.

Shared UI shells and the folder-wide UI rules live in `../README.md`.
