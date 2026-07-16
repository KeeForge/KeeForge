# Services Folder

This folder is the integration layer between app logic and the outside world: App Group storage, file/bookmark access, cloud SDKs, Keychain, system APIs, AutoFill helpers, and app-level support services.

## Open Next

- `Persistence/README.md` — database references, cached copies, local save, bookmarks, coordinated file access, and synced-folder detection.
- `Cloud/README.md` — cloud providers, account/token state, open/save sync, and deferred uploads.
- `Security/README.md` — biometrics, Keychain, passkey crypto, and screen-protection helpers.
- `AutoFill/README.md` — credential save/search helpers shared with the extension.
- `AppSupport/README.md` — settings, monetization, clipboard, haptics, and favicon fetching.

## Folder Map

- `Persistence` holds the file-system and App Group storage surfaces the app depends on, including `DatabaseListStore.swift`, `LocalDatabaseSaver.swift`, `SecurityScopedBookmarkManager.swift`, `CoordinatedFileReader.swift`, and `SharedVaultStore.swift`.
- `Cloud` holds provider abstractions plus the cloud-backed open/save pipeline, including `CloudProvider.swift`, `CloudSyncCoordinator.swift`, `CloudDatabaseSaver.swift`, `PendingUploadQueue.swift`, and `PendingUploadDrainer.swift`.
- `Security` holds device-security integrations such as `BiometricService.swift`, `KeychainService.swift`, `PasskeyCrypto.swift`, and `ScreenProtectionService.swift`.
- `AutoFill` holds extension-facing helpers such as `AutoFillSaveCoordinator.swift`, `CredentialMatcher.swift`, `CredentialIdentityStoreManager.swift`, and `PasswordGenerator.swift`.
- `AppSupport` holds app-scoped helpers that do not fit the more sensitive storage/security buckets, including `SettingsService.swift`, `StoreKitManager.swift`, `ReviewPromptService.swift`, `ClipboardService.swift`, `HapticService.swift`, `FaviconService.swift`, and the macOS-only `MacLockMonitor.swift` (the Mac lock-lifecycle driver; KeeForgeMac target only).

## Start Here

- `Persistence/DatabaseListStore.swift` is still the persisted source of truth for known databases, cached copies, read-only flags, edit acknowledgments, backup directories, and the active AutoFill database selection.
- `Persistence/LocalDatabaseSaver.swift` and `Cloud/CloudDatabaseSaver.swift` are still the main save-path entry points.
- `Cloud/CloudSyncCoordinator.swift` still owns cloud download-before-open and post-save cache/reference refresh behavior.
- `AutoFill/AutoFillSaveCoordinator.swift` still owns the extension-safe save path for new credentials.
- `Security/KeychainService.swift` still owns composite-key storage with biometric access control.

## Change Carefully

- Several service files are compiled into both the app and the AutoFill extension; see `../../AutoFillExtension/README.md`. If you add dependencies, keep them extension-safe and update `../../project.yml`.
- The favicon disk cache location is platform-split: iOS uses the App Group container (AutoFill reads it there), macOS uses the app's own sandbox container (Application Support) because the group container is world-readable on macOS 14 and the cache is a plaintext domain fingerprint of the vault. Keep `FaviconService`'s mac branch extension-safe. `Security/ScreenProtectionService.swift` is the layered macOS screen-privacy service (resign-active blur cover + best-effort `NSWindow.sharingType` capture blocking through a single choke point). See `../../docs/macos-security-notes.md`.
- App Group identifiers, bookmark semantics, backup directory layout, and Keychain access group behavior are compatibility boundaries. Avoid casual renames or storage format changes. Note the platform split for MSAL's token-cache keychain group: `com.microsoft.adalcache` on iOS vs `com.microsoft.identity.universalstorage` on macOS (see `Cloud/README.md` and `KeeForgeMac/KeeForgeMac.entitlements`).
- Keep SDK-specific cloud behavior behind `CloudProvider`-style abstractions so the rest of the app stays testable.
- Local and cloud-backed save flows intentionally share the same backup/cache rules but have different conflict checks: local files use open-time SHA512 only, while cloud save layers remote revision verification and typed write-scope failures on top.
- Pending-upload markers must stay durable, secret-free, and App-Group-relative because AutoFill may return before the main app is foregrounded to upload the cloud cache copy.
