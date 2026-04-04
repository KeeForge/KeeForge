# Cloud Drive Integration — Read-Only Sync

## Overview

Add native cloud drive integration so users can open .kdbx files directly from cloud storage without relying on the iOS Files app. Read-only: download and cache remote files, re-fetch when modified. No upload/write-back.

**Target order:** Dropbox → Google Drive → OneDrive

## Architecture

### CloudProvider Protocol

```swift
protocol CloudProvider: Identifiable {
    var id: String { get }              // "dropbox", "google-drive", "onedrive"
    var displayName: String { get }
    var iconName: String { get }        // SF Symbol or asset name

    func authenticate(from anchor: ASPresentationAnchor) async throws
    func isAuthenticated() -> Bool
    func signOut()

    func listFiles(path: String?, query: String?) async throws -> [CloudFile]
    func download(fileId: String) async throws -> Data
    func getMetadata(fileId: String) async throws -> CloudFileMetadata
}

struct CloudFile: Identifiable {
    let id: String                      // Provider-specific file ID
    let name: String
    let path: String
    let isFolder: Bool
    let modifiedDate: Date?
    let size: Int64?
}

struct CloudFileMetadata {
    let modifiedDate: Date
    let contentHash: String?            // Dropbox has content_hash, others use etag
    let size: Int64
}
```

### DatabaseReference Changes

Extend `DatabaseReference` to support cloud sources:

```swift
enum DatabaseSource {
    case local                          // Existing: security-scoped bookmark
    case cloud(provider: String, fileId: String, path: String)
}
```

Store cloud metadata alongside existing bookmark data. The local cached copy lives in the app's shared container (same as current files).

### Sync Flow

1. **First open:** OAuth → browse → pick file → download → cache locally → create `DatabaseReference` with `.cloud` source
2. **Subsequent opens:** Check remote metadata (modifiedDate/contentHash) vs cached → re-download if stale → open cached copy
3. **Offline:** Open last cached copy, show "offline" indicator
4. **Token refresh:** Handle silently; if token is revoked, prompt re-auth

### Token Storage

Keychain (shared app group) keyed by `cloud-token-{providerId}`. Store OAuth refresh token only — access tokens are ephemeral.

### UI

**Add Database flow** (DatabaseListView):
- Current "+" button opens `.fileImporter`
- Add a sheet/action sheet: "Open from Files" | "Dropbox" | "Google Drive" | etc.
- Cloud option → auth (if needed) → file browser → select .kdbx

**Cloud File Browser:**
- Simple NavigationStack with folder drill-down
- Filter to show only .kdbx files and folders
- Search bar for large vaults
- Reuse across all providers (just swap the `CloudProvider` instance)

**Database Row indicator:**
- Small cloud icon on DatabaseRowView for cloud-sourced databases
- Show provider icon (Dropbox/Drive/OneDrive) in database details

**Settings:**
- "Cloud Accounts" section listing connected accounts with sign-out option

## Phase 1: Dropbox

### Dependencies

- **SwiftyDropbox SDK** (official, SPM supported): `https://github.com/dropbox/SwiftyDropbox`
- Dropbox App Console: create app with `files.content.read` and `files.metadata.read` scopes
- URL scheme for OAuth callback: `db-{APP_KEY}`

### Auth

- `ASWebAuthenticationSession` via SwiftyDropbox's built-in PKCE flow
- No server needed — client-side OAuth with PKCE
- Store refresh token in Keychain

### API Mapping

| CloudProvider method | Dropbox API |
|---|---|
| `listFiles(path:)` | `files/list_folder` (filter `.kdbx` client-side) |
| `listFiles(query:)` | `files/search_v2` with `.kdbx` extension filter |
| `download(fileId:)` | `files/download` by path |
| `getMetadata(fileId:)` | `files/get_metadata` — use `content_hash` for change detection |

### Dropbox-Specific Notes

- Dropbox uses **paths** as primary identifiers (not opaque file IDs) — store the path in `DatabaseReference`
- `content_hash` is a reliable change detector (better than modifiedDate alone)
- Free accounts have device limits but API access is separate — our integration counts as one "linked app", not a device
- Rate limits: 150 requests/user/minute (more than enough for readonly)

### Info.plist / Entitlements

- Add URL scheme `db-{APP_KEY}` for OAuth redirect
- Add `LSApplicationQueriesSchemes: dbapi-2` (to detect Dropbox app)

## Test Plan

### Unit Tests

- `CloudFileMetadata` change detection: compare cached vs remote metadata, verify staleness logic
- `DatabaseReference` serialization round-trip with `.cloud` source
- Mock `CloudProvider` conformance: verify sync flow (auth → list → download → cache)
- Offline fallback: return cached copy when provider throws network error
- Token expiry handling: verify re-auth is triggered

### UI Tests

- Add database from cloud: tap "+" → select Dropbox → (mock auth) → browse folders → select .kdbx → verify appears in database list
- Cloud indicator: verify cloud icon appears on cloud-sourced database rows
- Sign out: Settings → Cloud Accounts → sign out → verify databases still openable from cache

### Manual Testing

- Fresh Dropbox auth flow (real OAuth)
- Browse deeply nested folders, pick a .kdbx
- Open database, lock, re-open (should use cache, not re-download)
- Modify the .kdbx on another device → re-open in KeeForge → verify fresh data
- Kill network → open cloud database → verify offline cache works
- Revoke app access from Dropbox settings → verify graceful re-auth prompt
- Multiple Dropbox accounts (if supported by SwiftyDropbox)

### Edge Cases

- .kdbx file deleted from Dropbox → show error, offer to remove from list
- File moved/renamed on Dropbox → detect via content_hash if path fails
- Very large database (>50MB) → progress indicator during download
- OAuth cancelled mid-flow → no crash, return to database list

## Future: Google Drive & OneDrive

Same `CloudProvider` protocol, different SDK/auth:

- **Google Drive:** GoogleSignIn + GoogleAPIClientForREST, `drive.readonly` scope
- **OneDrive:** MSAL + Microsoft Graph, `Files.Read` scope

The cloud file browser UI, caching layer, and DatabaseReference changes are shared — only the provider implementation differs. ~1-2 days each after Dropbox ships.

## Out of Scope (for now)

- Write-back / upload modified databases
- Conflict resolution
- Auto-sync in background (push notifications from cloud providers)
- WebDAV / self-hosted cloud (NextCloud, etc.)
