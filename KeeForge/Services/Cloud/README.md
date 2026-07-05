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
- `WebDAVModels.swift` holds the WebDAV config/credential value types, URL normalization + accountId derivation, and the `WebDAVConnecting` connect seam.
- `WebDAVPropfindParser.swift` is a pure `XMLParser`-based multistatus parser (DAV: namespace only) that yields `[WebDAVResource]`.
- `WebDAVClient.swift` is a `Sendable` transport (injectable closure; live ephemeral `URLSession` with same-origin redirect handling and preemptive Basic auth) plus the HTTP/URLError→`CloudProviderError` mapping.
- `WebDAVCloudProvider.swift` implements `CloudProvider` + `WebDAVConnecting` for WebDAV: stateless, credential-per-call from `CloudTokenStore`, ETag-based `rev`, and folder/.kdbx listing. Wired via `provider(for:)` but intentionally left out of `availableProviders` until the UI slice ships.

## Change Carefully

- Keep provider-specific behavior behind `CloudProvider` so view models and tests stay decoupled.
- Pending-upload markers must remain durable, secret-free, and App-Group-relative.
