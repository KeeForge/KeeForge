# KeeForge App Target

Use this folder as the main map for the app target. The subfolder READMEs hold the local detail; this file connects the main flows.

These sources compile into four targets: `KeeForge` (iOS app), `KeeForgeAutoFill` (iOS extension, selected files), `KeeForgeMac` (experimental native macOS app), and `KeeForgeMacAutoFill` (macOS extension, same allow-list as the iOS one). The Mac app compiles the full tree minus `Resources/LaunchScreen.storyboard`, plus the macOS-only `App/KeeForgeCommands.swift` and `Services/AppSupport/MacLockMonitor.swift` (both excluded from the iOS target) and two AutoFillExtension shells (`CredentialProviderViewControllerMac.swift`, `AutoFillSearchView.swift`) so `KeeForgeMacTests` can exercise them. The iOS `Info.plist` and `KeeForge.entitlements` live in this folder; the Mac equivalents in `../KeeForgeMac/`. Platform divergence goes through `Extensions/PlatformCompat.swift` for view-layer patterns and `#if os()` seams in Services — not all small: `Services/Security/ScreenProtectionService.swift` is two full per-platform implementations. Keep all four targets compiling when touching shared files. Shared `KeeForgeTests` sources also compile into the macOS-hosted `KeeForgeMacTests` target; `KeeForgeMacUITests` covers the Mac UI.

## Open Next

- `App/README.md` — scene lifecycle and root routing
- `Models/README.md` — parser, writer, edit-draft, and persisted models
- `Services/README.md` — persistence, cloud sync, security, AutoFill helpers, and app-support services
- `ViewModels/README.md` — observable app state, including draft/save ownership
- `Views/README.md` — SwiftUI screens and UI conventions
- `Extensions/README.md` — target-wide conformances and small shared extensions
- `Resources/README.md` — asset catalog and launch resources

## Cross-Cutting Flows

- Database list flow: `App/KeeForgeApp.swift` creates `DatabaseListViewModel`, which reads and mutates persisted database references through `Services/Persistence/DatabaseListStore.swift`.
- Unlock flow: `Views/UnlockView.swift` and the adaptive root shell in `App/KeeForgeApp.swift` drive `ViewModels/DatabaseViewModel.swift`, which resolves the database file, derives the composite key, parses via `Models/KDBXParser.swift`, and stores a per-session `SymmetricKey`.
- Adaptive navigation flow: compact layouts push from the database list into one active database session; regular-width layouts show the list+detail split only while the selected session is locked or unlocking — once unlocked, `App/RegularDatabaseWorkspaceView.swift` replaces the split view entirely as the workspace.
- Local edit/save flow: `ViewModels/DatabaseViewModel.swift` stages changes in `Models/DatabaseDraft.swift`, reuses `Models/KDBXWriter.swift` for encryption, and saves local files through `Services/Persistence/LocalDatabaseSaver.swift` with conflict checks, backups, and shared-cache refresh.
- Entry editing flow: `Views/EntryEditView.swift` and `ViewModels/EntryEditViewModel.swift` drive create/edit/delete entry drafts from the unlocked database UI, while `Views/PasswordGeneratorSheet.swift` and `Services/AutoFill/PasswordGenerator.swift` provide the reusable strong-password generator surface.
- Cloud database flow: cloud-backed `Models/DatabaseReference.swift` values carry `CloudSyncMetadata`; `Services/Cloud/CloudSyncCoordinator.swift` decides whether to reuse cache or download before open.
- Read-only/edit safety flow: `Models/DatabaseReference.swift` persists `isReadOnly`; `ViewModels/DatabaseViewModel.swift` refuses to save when it is set, and `Services/Persistence/LocalDatabaseSaver.swift` compares the open-time SHA-512 before overwriting.
- AutoFill handoff: the main app and extension share models plus selected services through `project.yml`, `SharedVaultStore`, App Group defaults, cached database copies, and Keychain entries; local saves must keep the shared cached copy aligned.
- AutoFill save flow: the extension can now generate/save new credentials through `Services/AutoFill/AutoFillSaveCoordinator.swift`, persist pending cloud uploads in `Services/Cloud/PendingUploadQueue.swift`, and rely on the main app's `Services/Cloud/PendingUploadDrainer.swift` to push cached encrypted bytes when the app becomes active.

## Working Rules

- Start from the folder that owns the behavior, then open the matching tests before changing code.
- If a change crosses app and extension boundaries, check both `../AutoFillExtension/README.md` and `../project.yml`.
- New source files here are picked up by `xcodegen generate` alone (the app and Mac targets use folder globs); only AutoFill-extension files need explicit `project.yml` edits, in both per-file allow-lists, which must stay identical.
