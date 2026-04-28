# Cloud Services

This folder owns provider abstractions plus the cloud-backed open/save pipeline.

## Main Files

- `CloudProvider.swift` and `CloudProviderRegistry.swift` define the provider boundary the rest of the app talks to.
- `CloudAccountStore.swift` and `CloudTokenStore.swift` persist provider account state and auth material.
- `CloudSyncCoordinator.swift` decides when to reuse cache, download before open, or refresh metadata after cloud saves.
- `CloudDatabaseSaver.swift` performs the cloud-backed save pipeline with provider revision verification, upload, cache refresh, and backup rotation.
- `CloudProvider.swift` also exposes create-only cloud uploads used by database creation; providers must use no-overwrite semantics for new files.
- `PendingUploadQueue.swift` and `PendingUploadDrainer.swift` handle deferred cloud uploads from the AutoFill save path.
- `DropboxCloudProvider.swift`, `OneDriveCloudProvider.swift`, and `UITestDropboxCloudProvider.swift` implement the real and test cloud integrations.

## Change Carefully

- Keep provider-specific behavior behind `CloudProvider` so view models and tests stay decoupled.
- Pending-upload markers must remain durable, secret-free, and App-Group-relative.
