# App Folder

This folder owns app startup, scene transitions, and the adaptive root shell that connects the database list to one active database session.

## Main File

- `KeeForgeApp.swift` creates the shared `DatabaseListViewModel`, owns the optional active `DatabaseViewModel`, chooses the compact vs regular-width root layout, and wires global scene-phase behavior. It also presents the cross-platform What's New sheet before any Quick Launch unlock sheet and resumes the pending database route after dismissal. On macOS it additionally declares the `Settings { }` scene (⌘,), sets the window `defaultSize`/min frame, publishes the active session via `.focusedSceneValue(\.databaseViewModel, ...)`, attaches `KeeForgeCommands`, and starts `MacLockMonitor` — the sole lock driver on macOS (the scene-phase `.background` lock path is iOS-only there because macOS backgrounds scenes on window minimize/app hide).
- `KeeForgeCommands.swift` (KeeForgeMac target only; excluded from the iOS target in `project.yml`) owns the macOS menu bar: New Entry ⌘N, Save ⌘S, Close Database ⇧⌘W, Copy Username ⇧⌘B, Copy Password ⇧⌘C (device-owner auth gated), Find ⌘F, Lock ⌘L. Commands reach the active `DatabaseViewModel` through `FocusedValues` — the one FocusedValues plumbing pattern in the codebase.
- `RegularDatabaseWorkspaceView.swift` owns the regular-width unlocked workspace. iOS/iPadOS keeps the two-column split view (`sidebarColumn` is a `NavigationStack` pushing `GroupListView`; entry detail in the detail column). macOS uses a dedicated three-column `macSplitView` (`#if os(macOS)`): a sidebar group tree (`MacGroupTreeRow`, a recursive `DisclosureGroup`/`.listStyle(.sidebar)` view whose rows are plain buttons carrying `group.navlink` with a manual selection highlight), a content column of entry rows (`entry.navlink`) or `SearchView` when searching, and the entry-detail column. Selection is driven by `DatabaseViewModel.selectedGroupID`/`selectedEntryID` (no pushed sidebar stacks — those render zero-height on macOS). The window title is the database name via `.navigationTitle`, with the group name as `.navigationSubtitle`. The Mac toolbar uses explicit `ToolbarItem` placements (lock, add-menu, sort, settings) plus `.searchable`, sized so nothing overflows at the 900pt minimum width. It also services the menu-bar/toolbar New Entry request (`DatabaseViewModel.newEntryRequestID` / `requestNewEntry()`) by presenting the entry editor in a single shared sheet targeting `selectedGroupID ?? visibleRootGroupID`. The old flat drill-down and its `group.back` toolbar button are retired on macOS.

## What Lives Here

- App launch routing: auto-open only when there is one quick-launch database.
- Scene protection: backgrounding locks the active database and shows the capture shield.
- Root presentation: compact layouts move from the database list into a full-screen database session; regular-width layouts keep the list visible in a split view and render the selected database session in the detail area.
- Session presentation: unlock, unlocking, and unlocked states are all part of the same selected-database flow rather than a modal sheet lifecycle.
- Auto-unlock orchestration: `lockCycleID` prevents repeated biometric retries for the same lock cycle.
- Pending upload draining: foreground activation and the AutoFill Darwin notification both trigger `PendingUploadDrainer` so queued cloud saves from the extension are pushed as soon as the app can do it.
- Version education: `WhatsNewPresentationService` claims each marketing version once, while `WhatsNewView` presents only curated feature content supported by the current platform. Quick Launch waits until that sheet closes so the two presentations never compete.

## Change Carefully

- Root navigation changes here usually ripple into `../Views/DatabaseListView.swift`, `../Views/UnlockView.swift`, `RegularDatabaseWorkspaceView.swift`, and `../../KeeForgeUITests/README.md`.
- Keep lifecycle policy here or in services/view models; do not hide app-wide state transitions inside individual views.
- If the app should behave differently on background/foreground, verify both compact and regular-width unlocked flows, AutoFill cache refresh behavior, and pending-upload drain timing together.
