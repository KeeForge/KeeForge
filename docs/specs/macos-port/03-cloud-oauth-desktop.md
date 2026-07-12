# Slice 03: Cloud OAuth on Desktop (Dropbox + OneDrive)

> Parent: [`epic.md`](./epic.md) · Depends on: 01

## Goal

Dropbox and OneDrive sign-in, browse, download, edit, upload, and conflict handling work on macOS, with tokens surviving relaunch — bringing cloud-backed vaults to parity with iOS.

## Scope

**In:**
- Replace the slice-01 throwing stubs in `DropboxCloudProvider.swift` / `OneDriveCloudProvider.swift` with real macOS auth flows.
- MSAL macOS token-cache configuration and verification.
- Developer-console registration of mac redirect URIs.
- End-to-end sync verification on macOS (coordinator/saver/queue code is already portable and must not change).

**Out:** WebDAV (already works after slice 01 — pure URLSession); any UI redesign of the cloud browser (slice 02 polished it); AutoFill's cloud-cached databases (slice 05 consumes the same caches unchanged).

## Affected areas

- Modified: `KeeForge/Services/Cloud/DropboxCloudProvider.swift` — macOS branch using SwiftyDropbox's desktop OAuth surface (`OAuthDesktop.swift`, confirmed present in the pinned SPM checkout: `authorizeFromControllerV2` desktop variant + `NSWorkspace`-based URL opening). The `db-$(DROPBOX_APP_KEY)` redirect scheme is already in the mac Info.plist (slice 01); completion arrives via the existing `onOpenURL` → `handleRedirectURL` path. The iOS `topViewController` UIKit traversal stays iOS-only.
- Modified: `KeeForge/Services/Cloud/OneDriveCloudProvider.swift` — `MSALWebviewParameters(authPresentationViewController:)` accepts an `NSViewController` on macOS (derive from the anchor window's `contentViewController`). No broker exists on macOS — remove any broker expectations from the mac path.
- Modified: `KeeForgeMac/KeeForgeMac.entitlements` — **verify and fix the MSAL keychain group**: macOS MSAL caches tokens under `com.microsoft.identity.universalstorage`, not the iOS `com.microsoft.adalcache` group currently mirrored from the iOS entitlements. Whichever group MSAL actually requires on macOS 14 goes in the mac entitlements; silent token refresh across relaunch is the acceptance test.
- Unchanged by design: `CloudSyncCoordinator.swift`, `CloudDatabaseSaver.swift`, `PendingUploadQueue.swift`/`PendingUploadDrainer.swift`, `WebDAV*` — all verified portable. If this slice finds itself editing them, stop and re-check the approach.
- External: register the macOS redirect URIs in the Dropbox and Azure app consoles (shared bundle ID `com.keevault.app` means the `msauth.com.keevault.app://auth` URI shape is unchanged).

## KeeForge bits

- **Targets:** both provider files remain in KeeForge + KeeForgeMac (they are not in the AutoFill allow-list). Entitlements file: KeeForgeMac only.
- **project.yml:** no target changes expected; only if the entitlements filename changes. Run `xcodegen generate` if touched.
- **Accessibility identifiers:** N/A — no view changes; the cloud-connect flows reuse existing screens and identifiers.

## Testing

- **Unit:** existing `DropboxCloudProviderTests`, `WebDAVCloudProviderTests`, `CloudProviderRegistryTests`, `CloudSyncModelsTests`, `CloudTokenStoreTests` must pass on `KeeForgeMacTests` (they exercise the portable logic around the auth seam). New: a test asserting the macOS provider paths no longer throw the slice-01 "unavailable" stub error and produce a well-formed auth configuration (auth itself is not unit-testable — it opens a browser/web view).
  Run slice: `-only-testing:KeeForgeMacTests/DropboxCloudProviderTests -only-testing:KeeForgeMacTests/CloudTokenStoreTests -only-testing:KeeForgeMacTests/CloudSyncModelsTests`.
- **Integration / UI:** `CloudSyncUITests` equivalents on mac only if the mocked providers (`UITestDropboxCloudProvider`) surface mac-specific flow differences; otherwise N/A — real OAuth cannot run in CI.
- **Manual (the real acceptance for this slice):**
  - Dropbox: sign in on macOS, browse, add a cloud database, unlock, edit, save → upload; kill and relaunch → silent token refresh, no re-auth prompt.
  - OneDrive: same full pass; confirm the token lands in the expected keychain access group (`security dump-keychain` or Keychain Access inspection) and survives relaunch.
  - Conflict path: modify the remote copy externally, save locally, verify the existing conflict handling runs on macOS.
  - Offline: launch with network disabled → cached cloud database opens read-only per existing behavior; pending upload queues and drains on reconnect (drain trigger comes from slice 02's MacLockMonitor became-active hook).
- **Edge cases that apply:** cancellation mid-OAuth (window closed), revoked token (re-auth prompt path), offline save → pending upload → drain, two databases on the same account, locked DB during background drain.

## Exit criteria

- [ ] Unit tests above pass on both platforms; iOS suite green.
- [ ] Manual end-to-end passes for both providers, incl. relaunch token survival.
- [ ] No force unwraps; secrets via `EncryptedValue`; heavy work off main.
- [ ] `xcodegen generate` if `project.yml` changed; `KeeForge/Services/README.md` updated if the provider seam notes change.
- [ ] CHANGELOG entry under `## Unreleased`.

## CHANGELOG entry

`- macOS: Dropbox and OneDrive sign-in and sync, with tokens persisted across relaunch.`
