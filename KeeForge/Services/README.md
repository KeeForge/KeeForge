# Services Folder

This folder is the integration layer between app logic and the outside world: Keychain, App Group storage, file bookmarks, cloud SDKs, system APIs, and AutoFill support.

## Main Clusters

- Database persistence and file access: `DatabaseListStore.swift`, `SharedVaultStore.swift`, `SecurityScopedBookmarkManager.swift`, `CoordinatedFileReader.swift`, `DocumentPickerService.swift`.
- Security and device integration: `BiometricService.swift`, `KeychainService.swift`, `ClipboardService.swift`, `ScreenProtectionService.swift`, `HapticService.swift`.
- Cloud sync: `CloudProvider.swift`, `CloudProviderRegistry.swift`, `CloudSyncCoordinator.swift`, `CloudAccountStore.swift`, `CloudTokenStore.swift`, `DropboxCloudProvider.swift`, `UITestDropboxCloudProvider.swift`.
- AutoFill and web helpers: `CredentialMatcher.swift`, `CredentialIdentityStoreManager.swift`, `PasskeyCrypto.swift`, `FaviconService.swift`.
- App settings and monetization: `SettingsService.swift`, `ReviewPromptService.swift`, `StoreKitManager.swift`.

## Files Agents Usually Need First

- `DatabaseListStore.swift` is the persisted source of truth for known databases, cached copies, active AutoFill database selection, and several UI-test bootstraps.
- `KeychainService.swift` stores composite keys with biometric access control.
- `CloudSyncCoordinator.swift` decides when a cloud-backed database must download before open.
- `SettingsService.swift` decides what is local-only vs App Group-shared with the extension.

## Change Carefully

- Several service files are compiled into both the app and the AutoFill extension; see `../../AutoFillExtension/README.md`. If you add dependencies, keep them extension-safe and update `../../project.yml`.
- App Group identifiers, bookmark semantics, and Keychain access group behavior are compatibility boundaries. Avoid casual renames or storage format changes.
- Keep SDK-specific cloud behavior behind `CloudProvider`-style abstractions so the rest of the app stays testable.
- Relevant unit tests are split by service area: database list/store, cloud account/token/provider, credential matching/identity, settings/shared storage, review prompts, and favicon caching.
