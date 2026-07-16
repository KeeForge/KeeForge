# Cloud Drive Integration — Read-Only Sync

## Overview

Add native cloud drive integration so users can open .kdbx files directly from cloud storage without relying on the iOS Files app. Read-only: download and cache remote files, re-fetch when modified. No upload/write-back.

**Current Target:** Dropbox

## Architecture

### CloudProvider Protocol

```swift
protocol CloudProvider: Identifiable {
    var id: String { get }              // "dropbox", "google-drive", "onedrive"
    var displayName: String { get }
    var iconName: String { get }        // SF Symbol or asset name

    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount
    func isAuthenticated(account: String) -> Bool
    func signOut(account: String)

    func listFiles(path: String?, query: String?) async throws -> [CloudFile]
    func download(fileId: String, to localURL: URL, progress: @escaping (Double) -> Void) async throws
    func getMetadata(fileId: String) async throws -> CloudFileMetadata
}

struct CloudAccount {
    let id: String                      // Provider user ID (Dropbox account_id, Google sub, etc.)
    let displayName: String             // "alex@gmail.com" or display name
    let provider: String
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
enum DatabaseSource: Codable {
    case local                          // Existing: security-scoped bookmark
    case cloud(CloudSyncMetadata)
}

struct CloudSyncMetadata: Codable {
    let provider: String                // "dropbox", "google-drive", "onedrive"
    let accountId: String               // Provider user ID — supports multiple accounts per provider
    let fileId: String                  // Provider-specific (Dropbox: path, Google: file ID)
    let displayPath: String             // Human-readable path for UI
    var remoteContentHash: String?      // Dropbox content_hash, Google md5Checksum, OneDrive quickXorHash
    var remoteModifiedAt: Date?
    var lastSyncedAt: Date?
    var lastSyncError: String?          // Nil when healthy
    var isStale: Bool { lastSyncError != nil }
}
```

The local cached copy lives in the app's shared container, keyed by `{provider}-{accountId}-{fileId-hash}`. This ensures multiple accounts or same-name files don't collide.

**Key file policy (v1):** Cloud sync covers `.kdbx` files only. Key files must be stored locally on the device. When a cloud database requires a key file, the user selects it from local storage as usual. Cloud-backed key files are out of scope for v1.

### Sync Flow

1. **First open:** OAuth → browse → pick file → download → cache locally → create `DatabaseReference` with `.cloud` source
2. **Subsequent opens:** Check remote metadata (modifiedDate/contentHash) vs cached → re-download if stale → open cached copy
3. **Offline:** Open last cached copy, show "offline" indicator
4. **Token refresh:** Handle silently; if token is revoked, prompt re-auth

### Token Storage

OAuth tokens stored in **Keychain with the shared access group** (`com.keevault.shared`, same entitlement the AutoFill extension already uses). This allows the AutoFill extension to refresh cached cloud databases when needed.

Keychain key format: `cloud-token-{providerId}-{accountId}` — supports multiple accounts per provider.

Store the **refresh token** only — access tokens are ephemeral and re-derived. If the refresh token is revoked (user disconnects from provider settings), prompt re-auth on next open.

### Cache & AutoFill Contract

Cached `.kdbx` files live in the shared app group container at `cloud-cache/{provider}-{accountId}/{fileId-hash}.kdbx`.

- **Main app:** On each database open, check remote metadata first. If network available and remote is newer → download fresh copy → replace cache → open. If network unavailable → open cached copy with "offline" badge.
- **AutoFill extension:** Always uses cached copy (no network calls in extension — too slow and memory-constrained). Main app is responsible for keeping the cache fresh.
- **After sign-out:** Cached files are **retained** (user may want offline access). Cloud icon changes to "disconnected" state. User can explicitly remove the database to delete the cache.
- **Staleness indicator:** If `lastSyncError` is set or `lastSyncedAt` is >24h ago, show a subtle warning on the database row.

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
| `download(fileId:to:progress:)` | `files/download` by path, streamed to temp file |
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
- Multiple Dropbox accounts (data model supports it; v1 UI may limit to one per provider)

### Edge Cases

- .kdbx file deleted from Dropbox → show error, offer to remove from list
- File moved/renamed on Dropbox → show "file not found" error with option to re-link (browse and pick new location) or remove
- Very large database (>50MB) → progress indicator during download (streaming, not in-memory)
- OAuth cancelled mid-flow → no crash, return to database list

