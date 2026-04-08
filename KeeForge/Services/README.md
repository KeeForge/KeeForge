# Services Folder

This folder is the integration layer between app logic and the outside world: Keychain, App Group storage, file bookmarks, cloud SDKs, system APIs, and AutoFill support.

## Main Clusters

- Database persistence, local save, and file access: `DatabaseListStore.swift`, `LocalDatabaseSaver.swift`, `SyncedFolderDetector.swift`, `SharedVaultStore.swift`, `SecurityScopedBookmarkManager.swift`, `CoordinatedFileReader.swift`, `DocumentPickerService.swift`.
- Security and device integration: `BiometricService.swift`, `KeychainService.swift`, `ClipboardService.swift`, `ScreenProtectionService.swift`, `HapticService.swift`.
- Cloud sync: `CloudProvider.swift`, `CloudProviderRegistry.swift`, `CloudSyncCoordinator.swift`, `CloudAccountStore.swift`, `CloudTokenStore.swift`, `DropboxCloudProvider.swift`, `UITestDropboxCloudProvider.swift`.
- AutoFill and web helpers: `CredentialMatcher.swift`, `CredentialIdentityStoreManager.swift`, `PasskeyCrypto.swift`, `FaviconService.swift`.
- App settings and monetization: `SettingsService.swift`, `ReviewPromptService.swift`, `StoreKitManager.swift`.

## Files Agents Usually Need First

- `DatabaseListStore.swift` is the persisted source of truth for known databases, cached copies, read-only and edit-acknowledgment flags, backup directories, active AutoFill database selection, and several UI-test bootstraps.
- `LocalDatabaseSaver.swift` handles atomic local saves, open-time conflict detection, backup rotation, and shared-cache refresh after a successful write.
- `SyncedFolderDetector.swift` classifies iCloud Drive and File Provider-backed local URLs before edit flows decide whether to continue or keep the database read-only.
- `KeychainService.swift` stores composite keys with biometric access control.
- `CloudSyncCoordinator.swift` decides when a cloud-backed database must download before open.
- `SettingsService.swift` decides what is local-only vs App Group-shared with the extension.

## Change Carefully

- Several service files are compiled into both the app and the AutoFill extension; see `../../AutoFillExtension/README.md`. If you add dependencies, keep them extension-safe and update `../../project.yml`.
- App Group identifiers, bookmark semantics, backup directory layout, and Keychain access group behavior are compatibility boundaries. Avoid casual renames or storage format changes.
- Keep SDK-specific cloud behavior behind `CloudProvider`-style abstractions so the rest of the app stays testable.
- Local save currently covers local/bookmark-backed databases and shared cached copies; cloud save is still pending and should not be silently approximated.
- Relevant unit tests are split by service area: database list/store, local save, synced-folder detection, cloud account/token/provider, credential matching/identity, settings/shared storage, review prompts, and favicon caching.
