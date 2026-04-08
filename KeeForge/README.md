# KeeForge App Target

Use this folder as the main map for the app target. The subfolder READMEs hold the local detail; this file connects the main flows.

## Open Next

- `App/README.md` — scene lifecycle and root routing
- `Models/README.md` — parser, writer, edit-draft, and persisted models
- `Services/README.md` — storage, local save, cloud sync, device integration, Keychain, App Group
- `ViewModels/README.md` — observable app state, including draft/save ownership
- `Views/README.md` — SwiftUI screens and UI conventions
- `Extensions/README.md` — target-wide conformances and small shared extensions
- `Resources/README.md` — asset catalog and launch resources

## Cross-Cutting Flows

- Database list flow: `App/KeeForgeApp.swift` creates `DatabaseListViewModel`, which reads and mutates persisted database references through `Services/DatabaseListStore.swift`.
- Unlock flow: `Views/UnlockView.swift` drives `ViewModels/DatabaseViewModel.swift`, which resolves the database file, derives the composite key, parses via `Models/KDBXParser.swift`, and stores a per-session `SymmetricKey`.
- Local edit/save flow: `ViewModels/DatabaseViewModel.swift` stages changes in `Models/DatabaseDraft.swift`, reuses `Models/KDBXWriter.swift` for encryption, and saves local files through `Services/LocalDatabaseSaver.swift` with conflict checks, backups, and shared-cache refresh.
- Cloud database flow: cloud-backed `Models/DatabaseReference.swift` values carry `CloudSyncMetadata`; `Services/CloudSyncCoordinator.swift` decides whether to reuse cache or download before open.
- Read-only/edit safety flow: `Models/DatabaseReference.swift` persists `isReadOnly` and `editsAcknowledgedAt`; `Services/SyncedFolderDetector.swift` classifies bookmark-backed synced folders before edit flows proceed.
- AutoFill handoff: the main app and extension share models plus selected services through `project.yml`, `SharedVaultStore`, App Group defaults, cached database copies, and Keychain entries; local saves must keep the shared cached copy aligned.

## Working Rules

- Start from the folder that owns the behavior, then open the matching tests before changing code.
- If a change crosses app and extension boundaries, check both `../AutoFillExtension/README.md` and `../project.yml`.
- If you add a new source file here, XcodeGen will not see it until `project.yml` is updated and `xcodegen generate` is run.
