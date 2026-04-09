# Services Folder

This folder is the integration layer between app logic and the outside world: Keychain, App Group storage, file bookmarks, cloud SDKs, system APIs, and AutoFill support.

## Main Clusters

- Database persistence, local/cloud save, and file access: `DatabaseListStore.swift`, `LocalDatabaseSaver.swift`, `CloudDatabaseSaver.swift`, `SyncedFolderDetector.swift`, `SharedVaultStore.swift`, `SecurityScopedBookmarkManager.swift`, `CoordinatedFileReader.swift`, `DocumentPickerService.swift`.
- AutoFill save + deferred cloud upload helpers: `AutoFillSaveCoordinator.swift`, `PendingUploadQueue.swift`, `PendingUploadDrainer.swift`.
- Security and device integration: `BiometricService.swift`, `KeychainService.swift`, `ClipboardService.swift`, `ScreenProtectionService.swift`, `HapticService.swift`.
- Cloud sync: `CloudProvider.swift`, `CloudProviderRegistry.swift`, `CloudSyncCoordinator.swift`, `CloudAccountStore.swift`, `CloudTokenStore.swift`, `DropboxCloudProvider.swift`, `UITestDropboxCloudProvider.swift`.
- AutoFill and web helpers: `CredentialMatcher.swift`, `CredentialIdentityStoreManager.swift`, `PasskeyCrypto.swift`, `FaviconService.swift`.
- Editing helpers: `PasswordGenerator.swift` provides the reusable strong-password generator consumed by both the main app and the AutoFill credential-creation flow.
- App settings and monetization: `SettingsService.swift`, `ReviewPromptService.swift`, `StoreKitManager.swift`.

## Files Agents Usually Need First

- `DatabaseListStore.swift` is the persisted source of truth for known databases, cached copies, read-only and edit-acknowledgment flags, backup directories, active AutoFill database selection, and several UI-test bootstraps.
- `LocalDatabaseSaver.swift` handles atomic local saves, open-time conflict detection, backup rotation, and shared-cache refresh after a successful write.
- `CloudDatabaseSaver.swift` mirrors the local save pipeline for Dropbox-backed databases: cache SHA verification, remote rev verification, upload, cache refresh, and backup rotation.
- `AutoFillSaveCoordinator.swift` is the shared write path the extension uses to stage a new entry, save encrypted bytes through `LocalDatabaseSaver`, enqueue cloud markers, and refresh credential identities.
- `PendingUploadQueue.swift` persists durable App Group markers that point at encrypted cache files, not plaintext edit payloads.
- `PendingUploadDrainer.swift` scans those markers on app active / Darwin notification, retries safe rev-advance cases, and surfaces write-scope or auth failures back to the database list.
- `SyncedFolderDetector.swift` classifies iCloud Drive and File Provider-backed local URLs before edit flows decide whether to continue or keep the database read-only.
- `KeychainService.swift` stores composite keys with biometric access control.
- `CloudSyncCoordinator.swift` decides when a cloud-backed database must download before open and applies successful cloud-save uploads back into the cache plus persisted reference metadata.
- `DropboxCloudProvider.swift` owns Dropbox OAuth scope requests, rev-aware uploads, and write-scope upgrade detection.
- `SettingsService.swift` decides what is local-only vs App Group-shared with the extension.

## Change Carefully

- Several service files are compiled into both the app and the AutoFill extension; see `../../AutoFillExtension/README.md`. If you add dependencies, keep them extension-safe and update `../../project.yml`.
- App Group identifiers, bookmark semantics, backup directory layout, and Keychain access group behavior are compatibility boundaries. Avoid casual renames or storage format changes.
- Keep SDK-specific cloud behavior behind `CloudProvider`-style abstractions so the rest of the app stays testable.
- Local and Dropbox-backed save flows intentionally share the same backup/cache rules but have different conflict checks: local files use open-time SHA512 only, while cloud save layers remote `rev` verification and typed write-scope failures on top.
- Pending-upload markers must stay durable, secret-free, and App-Group-relative because AutoFill may return before the main app is foregrounded to upload the cloud cache copy.
- Relevant unit tests are split by service area: database list/store, local/cloud save, synced-folder detection, cloud account/token/provider, credential matching/identity, settings/shared storage, review prompts, and favicon caching.
