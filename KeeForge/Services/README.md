# Services Folder

This folder is the integration layer between app logic and the outside world: App Group storage, file/bookmark access, cloud SDKs, Keychain, system APIs, AutoFill helpers, and app-level support services.

## Open Next

- `Persistence/README.md` — database references, cached copies, local save, bookmarks, coordinated file access, and synced-folder detection.
- `Cloud/README.md` — cloud providers, account/token state, open/save sync, and deferred uploads.
- `Security/README.md` — biometrics, Keychain, passkey crypto, and screen-protection helpers.
- `AutoFill/README.md` — credential save/search helpers shared with the extension.
- `AppSupport/README.md` — settings, monetization, clipboard, haptics, and favicon fetching.

## Folder Map

- `Persistence` holds the file-system and App Group storage surfaces the app depends on, including `DatabaseListStore.swift`, `LocalDatabaseSaver.swift`, `SecurityScopedBookmarkManager.swift`, `CoordinatedFileReader.swift`, `SharedVaultStore.swift`, and `DatabaseFileInfoLoader.swift`; see `Persistence/README.md` for the shared-cache read/write split and the no-unlock Database Details loader.
- `Cloud` holds provider abstractions plus the cloud-backed open/save pipeline, including `CloudProvider.swift`, `CloudSyncCoordinator.swift`, `CloudDatabaseSaver.swift`, `PendingUploadQueue.swift`, and `PendingUploadDrainer.swift`.
- `Security` holds device-security integrations such as `BiometricService.swift`, `KeychainService.swift`, `PasskeyCrypto.swift`, and `ScreenProtectionService.swift`.
- `AutoFill` holds extension-facing helpers such as `AutoFillSaveCoordinator.swift`, `CredentialMatcher.swift`, `CredentialIdentityStoreManager.swift`, and `PasswordGenerator.swift`.
- `AppSupport` holds app-scoped helpers outside the storage/security buckets, including `SettingsService.swift`, `StoreKitManager.swift`, `ReviewPromptService.swift`, `ClipboardService.swift`, `HapticService.swift`, `FaviconService.swift`, and the macOS-only `MacLockMonitor.swift` (the Mac lock-lifecycle driver; KeeForgeMac target only). Two sensitive surfaces live here too: `FeedbackSubmissionService.swift` performs a user-initiated network POST, and `AttachmentPreviewFileStore.swift` writes plaintext attachment previews to a temp directory (cleaned on lock/dismiss) — details in `AppSupport/README.md`.

## Start Here

- `Persistence/DatabaseListStore.swift` is the persisted source of truth for known databases (`DatabaseReference`: read-only flag, per-database `autoFillEnabled`, `lastMasterKeyChangeAt`, cloud sync metadata), cached copies, backup directories, and the active AutoFill database selection.
- `Persistence/LocalDatabaseSaver.swift` and `Cloud/CloudDatabaseSaver.swift` are the main save-path entry points.
- `Cloud/CloudSyncCoordinator.swift` owns cloud download-before-open and post-save cache/reference refresh behavior.
- `AutoFill/AutoFillSaveCoordinator.swift` owns the extension-safe save path for new credentials.
- `Security/KeychainService.swift` owns composite-key storage with biometric access control.

## Change Carefully

- Several service files are compiled into both the app and the AutoFill extension; see `../../AutoFillExtension/README.md`. If you add dependencies, keep them extension-safe and update `../../project.yml`. The AutoFill shared source list is duplicated as two byte-identical allow-lists in `../../project.yml`, delimited by the `>>> SHARED AUTOFILL ALLOW-LIST` / `<<< SHARED AUTOFILL ALLOW-LIST` marker comments under the `KeeForgeAutoFill` and `KeeForgeMacAutoFill` targets; keep them literally identical (same paths, same order) and always edit both together. Separately, the `KeeForgeMac` app target compiles the *entire* `KeeForge/Services` tree (only `AppSupport/MacLockMonitor.swift` is excluded from the iOS app target), so every new service must compile on macOS.
- `AppSupport/ClipboardService.swift` is on the shared AutoFill allow-list, but only its iOS branch is ever called from an extension (opt-in "Copy Verification Code on AutoFill"). The macOS branch clears through an in-process timer that would die with the extension, so the coordinator gates the behavior on `#if os(iOS)`; the Mac extension compiles the AppKit branch without calling it. `SettingsService.clipboardTimeout` therefore lives in the App Group defaults (with a one-time read-through migration from the legacy app-local value) so both processes agree on the expiry.
- Favicon fetching (DuckDuckGo, opt-in, default off) has a platform-split plaintext disk cache — full statement in `AppSupport/README.md`; keep `FaviconService`'s mac branch extension-safe. `Security/ScreenProtectionService.swift` hosts both platforms' screen-privacy implementations — see `Security/README.md` and `../../docs/macos-security-notes.md`.
- App Group identifiers, bookmark semantics, backup directory layout, and Keychain access group behavior are compatibility boundaries. Avoid casual renames or storage format changes. `KeeForgeTests/AppGroupGuardrailTests.swift` pins the App Group write surface — full statement in `Persistence/README.md`'s guardrail section. MSAL's token-cache keychain group is platform-split; see `Cloud/README.md`.
- Keychain access-group ordering invariant: `com.keevault.sharedkeychain` must stay FIRST in every target's `keychain-access-groups` array or the shared composite keys are stranded — full statement in `Security/README.md`.
- Keep SDK-specific cloud behavior behind `CloudProvider`-style abstractions so the rest of the app stays testable.
- Local and cloud-backed save flows share the same backup/cache rules but differ on conflict checks: local files gate on the `SaveBaseline` hashes (open-time SHA512, plus the reconciled remote hash during a merge save); cloud save layers remote revision verification and typed write-scope failures on top. Timestamped backups are written in three places — `Persistence/LocalDatabaseSaver.swift` and `Cloud/CloudDatabaseSaver.swift` (both prune to keep the 5 newest via `DatabaseListStore.pruneBackups`), plus `Cloud/CloudSyncCoordinator.swift`, which backs up the shared cache before a sync-down overwrites a not-yet-uploaded AutoFill save.
- Pending-upload marker invariants: see `Cloud/README.md`.
