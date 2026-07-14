# App Folder

This folder owns app startup, scene transitions, and the adaptive root shell that connects the database list to one active database session.

## Main File

- `KeeForgeApp.swift` creates the shared `DatabaseListViewModel`, owns the optional active `DatabaseViewModel`, chooses the compact vs regular-width root layout, and wires global scene-phase behavior. On macOS it additionally declares the `Settings { }` scene (⌘,), sets the window `defaultSize`/min frame, publishes the active session via `.focusedSceneValue(\.databaseViewModel, ...)`, attaches `KeeForgeCommands`, and starts `MacLockMonitor` — the sole lock driver on macOS (the scene-phase `.background` lock path is iOS-only there because macOS backgrounds scenes on window minimize/app hide).
- `KeeForgeCommands.swift` (KeeForgeMac target only; excluded from the iOS target in `project.yml`) owns the macOS menu bar: New Entry ⌘N, Save ⌘S, Close Database ⇧⌘W, Copy Username ⇧⌘B, Copy Password ⇧⌘C (device-owner auth gated), Find ⌘F, Lock ⌘L. Commands reach the active `DatabaseViewModel` through `FocusedValues` — the one FocusedValues plumbing pattern in the codebase.
- `RegularDatabaseWorkspaceView.swift` owns the regular-width unlocked workspace used by iPad-style layouts and the Mac. On macOS it also services the menu-bar New Entry request (`DatabaseViewModel.newEntryRequestID`) by presenting the entry editor in a sheet, and it replaces the sidebar `NavigationStack` with flat group drill-down (`navigationPath` as the trail, `group.back` toolbar button) because pushed sidebar stacks render zero-height on macOS.

## What Lives Here

- App launch routing: auto-open only when there is one quick-launch database.
- Scene protection: backgrounding locks the active database and shows the capture shield.
- Root presentation: compact layouts move from the database list into a full-screen database session; regular-width layouts keep the list visible in a split view and render the selected database session in the detail area.
- Session presentation: unlock, unlocking, and unlocked states are all part of the same selected-database flow rather than a modal sheet lifecycle.
- Auto-unlock orchestration: `lockCycleID` prevents repeated biometric retries for the same lock cycle.
- Pending upload draining: foreground activation and the AutoFill Darwin notification both trigger `PendingUploadDrainer` so queued cloud saves from the extension are pushed as soon as the app can do it.

## Change Carefully

- Root navigation changes here usually ripple into `../Views/DatabaseListView.swift`, `../Views/UnlockView.swift`, `RegularDatabaseWorkspaceView.swift`, and `../../KeeForgeUITests/README.md`.
- Keep lifecycle policy here or in services/view models; do not hide app-wide state transitions inside individual views.
- If the app should behave differently on background/foreground, verify both compact and regular-width unlocked flows, AutoFill cache refresh behavior, and pending-upload drain timing together.
