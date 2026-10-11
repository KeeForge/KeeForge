# Shared App Sources

**Scope:** the source tree shared by every KeeForge target, and the rules for changing it across targets. Read the owning subfolder's `AGENTS.md` before changing its code.

## Targets and platforms

These sources compile into four targets, wired in `../project.yml`:

- `KeeForge` (iOS app): the folder globs, minus the macOS-only files below.
- `KeeForgeMac` (macOS app): the whole tree, with the exclusions below.
- `KeeForgeAutoFill` and `KeeForgeMacAutoFill` (AutoFill extensions): `Models/` plus an explicit allow-list of service and view files. The two lists must stay byte-identical.

Keep all four compiling when a shared file changes. `KeeForgeTests` also compiles into the Mac-hosted `KeeForgeMacTests`.

Exclusions in `../project.yml`:

- The Mac app omits `Resources/LaunchScreen.storyboard`, `Services/Cloud/DropboxCloudProvider.swift`, and `Services/Cloud/OneDriveCloudProvider.swift`. Omitting the two providers is what lets the Mac app drop the Dropbox and MSAL packages.
- The iOS app omits the macOS-only `App/KeeForgeCommands.swift` and `Services/AppSupport/{MacLockMonitor,MacWindowCloseGuard,MacQuickAccessController,MacGlobalHotKey}.swift`.
- Both apps compile `../AutoFillExtension/CredentialProviderCoordinator.swift` so hosted unit tests can reach it. The Mac app also compiles the Mac AutoFill shell and its views for the same reason.
- The iOS `Info.plist` and `KeeForge.entitlements` live here; the Mac equivalents are in `../KeeForgeMac/`.

What each platform offers differs from what compiles:

- Cloud sync: iOS offers Dropbox, OneDrive, WebDAV, and FTP. The Mac app offers WebDAV and FTP only (`CloudProviderKind.isAvailableOnCurrentPlatform`).
- Mac AutoFill fills passwords, passkeys, and one-time codes and saves a passkey registration. The system offers no password-save, password-generation, or picker-created entry flow there. Details in [../AutoFillExtension/AGENTS.md](../AutoFillExtension/AGENTS.md).

## Workflows

- App and Mac targets use folder globs in `../project.yml`; `xcodegen generate` picks up new files. The `KeeForgeAutoFill` and `KeeForgeMacAutoFill` shared-source allow-lists must stay byte-identical. Edit both together and keep shared imports/APIs extension-safe; read `../AutoFillExtension/AGENTS.md` when changing extension-shared code.
- For navigation, editor lifecycle, Settings effects, or launch/URL routing, read `ViewModels/AGENTS.md` even when changing a shell or view. It defines the reusable owners and their test contracts. Shared presentation rules live in `Views/AGENTS.md`; platform adapters live in `App/` and the relevant view folder.
- When adding or changing database creation, edit operations, KDBX parser/writer behavior, protected fields, unknown XML handling, AutoFill save, cloud save, or local save, update `../KeeForgeTests/KDBXCompatibilityTests.swift`. Update the compatibility artifact gate if the supported compatibility matrix changes; its workflow is in `../ci_scripts/AGENTS.md`.

## Platform divergence

- View layer: add the difference to `Extensions/PlatformCompat.swift` rather than scattering `#if os()` through Views.
- Services and App: use `#if os()` at the seam where behavior genuinely differs. `Services/Security/ScreenProtectionService.swift` is two full per-platform implementations, not a small seam.

## Cross-cutting flows

Flows that span three or more folders, as the types that own each step in order. Each folder's `AGENTS.md` holds the rules for its own step.

- Open and unlock: `Views/Unlock/UnlockView` and `App/KeeForgeApp` drive `ViewModels/DatabaseViewModel`, which asks `Services/Cloud/CloudSyncCoordinator` for the cached or downloaded file (cloud references only), derives the composite key, and parses with `Models/KDBXParser`.
- Save and conflict: `DatabaseViewModel` stages edits in `Models/DatabaseDraft`, encrypts with `Models/KDBXWriter`, and saves through `Services/Persistence/LocalDatabaseSaver` or `Services/Cloud/CloudDatabaseSaver`. A conflict is reconciled by `Models/KDBXMerger` and re-enters the same save path.
- Verification-code enrollment: an `otpauth://` link goes `App/KeeForgeApp` -> `ViewModels/AppRoutingCoordinator` (parses `Models/OTPAuthURI`) -> `ViewModels/TOTPEnrollmentViewModel` -> `Views/TOTP/TOTPEnrollmentDestinationView` -> `Views/Entry/EntryEditView`.
- AutoFill read: the app and extensions share models and selected services through `../project.yml`, App Group storage (`Services/Persistence/SharedVaultStore`, `DatabaseListStore`), cached database copies, and Keychain items. A local save must keep the shared cached copy aligned.
- AutoFill save: `../AutoFillExtension/CredentialProviderCoordinator` -> `Services/AutoFill/AutoFillSaveCoordinator` -> `Services/Persistence/LocalDatabaseSaver` into the cache, plus a `Services/Cloud/PendingUploadQueue` marker for cloud databases. The app's `Services/Cloud/PendingUploadDrainer`, owned by `ViewModels/DatabaseListViewModel`, uploads when the app becomes active.

## See also

- Code: [App](App/AGENTS.md), [Models](Models/AGENTS.md), [ViewModels](ViewModels/AGENTS.md), [Extensions](Extensions/AGENTS.md), [Views](Views/AGENTS.md), [Services](Services/AGENTS.md), [Resources](Resources/README.md)
- [../AutoFillExtension/AGENTS.md](../AutoFillExtension/AGENTS.md), [../KeeForgeMac/README.md](../KeeForgeMac/README.md)
- Tests: [../KeeForgeTests/AGENTS.md](../KeeForgeTests/AGENTS.md)
