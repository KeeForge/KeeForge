# KeeForge App Target

Use this folder as the main map for the app target. The subfolder READMEs hold the local detail; this file connects the main flows.

These sources compile into four targets: `KeeForge` (iOS app), `KeeForgeAutoFill` (iOS extension, selected files), `KeeForgeMac` (experimental native macOS app), and `KeeForgeMacAutoFill` (macOS extension, same allow-list as the iOS one). The Mac app compiles the full tree minus `Resources/LaunchScreen.storyboard`, plus the macOS-only `App/KeeForgeCommands.swift`, `Services/AppSupport/MacLockMonitor.swift`, and `Services/AppSupport/MacWindowCloseGuard.swift` (all excluded from the iOS target) and two AutoFillExtension shells (`CredentialProviderViewControllerMac.swift`, `AutoFillSearchView.swift`) so `KeeForgeMacTests` can exercise them; both app targets additionally compile `../AutoFillExtension/CredentialProviderCoordinator.swift` so the hosted unit tests can exercise it. The iOS `Info.plist` and `KeeForge.entitlements` live in this folder; the Mac equivalents in `../KeeForgeMac/`. Platform divergence goes through `Extensions/PlatformCompat.swift` for view-layer patterns and `#if os()` seams in Services — not all small: `Services/Security/ScreenProtectionService.swift` is two full per-platform implementations. Keep all four targets compiling when touching shared files. Shared `KeeForgeTests` sources also compile into the macOS-hosted `KeeForgeMacTests` target; `KeeForgeMacUITests` covers the Mac UI.

Each subfolder's `CLAUDE.md` loads automatically when you work in it; `Services/README.md`, `Views/README.md`, and `Resources/README.md` are opened on demand.

## Cross-Cutting Flows

- Database list flow: `App/KeeForgeApp.swift` creates `DatabaseListViewModel`, which reads and mutates persisted database references through `Services/Persistence/DatabaseListStore.swift`.
- Unlock flow: `Views/Unlock/UnlockView.swift` and the adaptive root shell in `App/KeeForgeApp.swift` drive `ViewModels/DatabaseViewModel.swift`, which resolves the database file, derives the composite key, parses via `Models/KDBXParser.swift`, and stores a per-session `SymmetricKey`.
- Adaptive navigation flow: compact layouts push from the database list into one active database session; regular-width layouts show the list+detail split only while the selected session is locked or unlocking — once unlocked, `App/RegularDatabaseWorkspaceView.swift` replaces the split view entirely as the workspace.
- Local edit/save flow: `ViewModels/DatabaseViewModel.swift` stages changes in `Models/DatabaseDraft.swift`, reuses `Models/KDBXWriter.swift` for encryption, and saves local files through `Services/Persistence/LocalDatabaseSaver.swift` with conflict checks, backups, and shared-cache refresh. A save conflict can be resolved by record-level merge: `Models/KDBXMerger.swift` reconciles the two copies and the result re-enters the same save path gated on the reconciled remote hash.
- Entry editing flow: `Views/Entry/EntryEditView.swift` and `ViewModels/EntryEditViewModel.swift` drive create/edit/delete entry drafts from the unlocked database UI, while `Views/Components/PasswordGeneratorSheet.swift` and `Services/AutoFill/PasswordGenerator.swift` provide the reusable strong-password generator surface.
- Verification-code enrollment flow: an incoming `otpauth://` link runs `App/KeeForgeApp.swift` → `Models/OTPAuthURI.swift` → `ViewModels/TOTPEnrollmentViewModel.swift` → `Views/TOTP/TOTPEnrollmentDestinationView.swift` → `Views/Entry/EntryEditView.swift` → `Models/DatabaseDraft.swift`.
- Cloud database flow: cloud-backed `Models/DatabaseReference.swift` values carry `CloudSyncMetadata`; `Services/Cloud/CloudSyncCoordinator.swift` decides whether to reuse cache or download before open.
- Read-only/edit safety flow: `Models/DatabaseReference.swift` persists `isReadOnly`; `ViewModels/DatabaseViewModel.swift` refuses to save when it is set, and `Services/Persistence/LocalDatabaseSaver.swift` compares the open-time SHA-512 before overwriting.
- AutoFill handoff: the main app and extension share models plus selected services through `project.yml`, `SharedVaultStore`, App Group defaults, cached database copies, and Keychain entries; local saves must keep the shared cached copy aligned.
- AutoFill save flow: the extension generates/saves new credentials through `Services/AutoFill/AutoFillSaveCoordinator.swift`, persists pending cloud uploads in `Services/Cloud/PendingUploadQueue.swift`, and relies on the main app's `Services/Cloud/PendingUploadDrainer.swift` to push cached encrypted bytes when the app becomes active.

## Working Rules

- Start from the folder that owns the behavior, then open the matching tests before changing code.
- If a change crosses app and extension boundaries, check both `../AutoFillExtension/AGENTS.md` and `../project.yml`.
- Adding files: folder globs vs. the AutoFill allow-lists — see `AGENTS.md` → Workflows.
