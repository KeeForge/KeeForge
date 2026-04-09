# App Folder

This folder owns app startup, scene transitions, and the top-level split between the database list and an active database session.

## Main File

- `KeeForgeApp.swift` creates the shared `DatabaseListViewModel`, owns the optional active `DatabaseViewModel`, and wires global scene-phase behavior.

## What Lives Here

- App launch routing: auto-open only when there is one quick-launch database.
- Scene protection: backgrounding locks the active database and shows the capture shield.
- Root presentation: the database list stays in the main window; an active database is presented as a sheet.
- Auto-unlock orchestration: `lockCycleID` prevents repeated biometric retries for the same lock cycle.
- Pending upload draining: foreground activation and the AutoFill Darwin notification both trigger `PendingUploadDrainer` so queued cloud saves from the extension are pushed as soon as the app can do it.

## Change Carefully

- Root navigation changes here usually ripple into `../Views/DatabaseListView.swift`, `../Views/UnlockView.swift`, and `../../KeeForgeUITests/README.md`.
- Keep lifecycle policy here or in services/view models; do not hide app-wide state transitions inside individual views.
- If the app should behave differently on background/foreground, verify the unlocked app flow, AutoFill cache refresh behavior, and pending-upload drain timing together.
