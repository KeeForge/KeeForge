# App Folder

This folder owns app startup, scene transitions, and the adaptive root shell that connects the database list to one active database session.

## Main File

- `KeeForgeApp.swift` creates the shared `DatabaseListViewModel`, owns the optional active `DatabaseViewModel`, chooses the compact vs regular-width root layout, and wires global scene-phase behavior.
- `RegularDatabaseWorkspaceView.swift` owns the regular-width unlocked workspace used by iPad-style layouts.

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
