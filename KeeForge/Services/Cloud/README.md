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
- `UITestWebDAVCloudProvider.swift` is the WebDAV UI-test double (mirrors `UITestDropboxCloudProvider`): gated by `-ui-testing` + `UI_TEST_WEBDAV_PAYLOAD_JSON`, conforms to `CloudProvider` + `WebDAVConnecting`, and is swapped in by `provider(for:)` when enabled.
- `WebDAVModels.swift` holds the WebDAV config/credential value types, HTTPS-by-default URL normalization with explicit HTTP opt-in, accountId derivation, and the `WebDAVConnecting` connect seam.
- `WebDAVPropfindParser.swift` is a pure `XMLParser`-based multistatus parser (DAV: namespace only) that yields `[WebDAVResource]`.
- `WebDAVClient.swift` is a `Sendable` transport (injectable closure; live ephemeral `URLSession` with same-origin redirect handling and preemptive Basic auth) plus the HTTP/URLError→`CloudProviderError` mapping.
- `WebDAVCloudProvider.swift` implements `CloudProvider` + `WebDAVConnecting` for WebDAV: stateless, credential-per-call from `CloudTokenStore`, ETag-based `rev`, and folder/.kdbx listing. Wired via `provider(for:)` but intentionally left out of `availableProviders` until the UI slice ships.

## Change Carefully

- Keep provider-specific behavior behind `CloudProvider` so view models and tests stay decoupled.
- macOS UI gate: Dropbox and OneDrive are temporarily hidden from the macOS UI (add/import menus and the New Database destination picker) via the single `CloudProviderKind.isAvailableOnCurrentPlatform` choke point, which filters `availableProviders` and `DatabaseCreationDestinationChoice.availableChoices`. The OAuth/sync code paths stay compiled and tested; `provider(for:)` is intentionally left unfiltered so already-connected cloud databases still resolve and open on macOS. WebDAV stays user-visible on every platform. TODO(macos-port): re-enable once the macOS cloud OAuth flows are validated end-to-end.
- Pending-upload markers must remain durable, secret-free, and App-Group-relative.
- Platform auth seams: `DropboxCloudProvider` uses SwiftyDropbox's desktop OAuth on macOS (system browser via `NSWorkspace`; completion returns through the `db-<appkey>` URL scheme into `handleRedirectURL`, same as iOS), while `OneDriveCloudProvider` presents MSAL from the anchor window's `contentViewController` and never handles redirect URLs on macOS (MSAL's web session intercepts them internally; `handleMSALResponse` is iOS-only and there is no macOS broker). Only the presentation layer is platform-gated; token storage, listing, download, and upload code stays shared.
- MSAL's macOS token cache lives in the `com.microsoft.identity.universalstorage` keychain group (iOS uses `com.microsoft.adalcache`); the group is declared in `KeeForgeMac/KeeForgeMac.entitlements` and silent OneDrive token refresh across relaunch breaks without it.
