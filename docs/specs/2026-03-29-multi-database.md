# Multi-Database Home Screen — Spec

## Overview

Overhaul the startup screen from a single-database unlock view to a **database list** (similar to Strongbox / KeePassium), allowing users to manage multiple .kdbx files with per-database state, credentials, and key file associations.

## Current State

- **Single database only** — `SharedVaultStore` stores one bookmark + one cached copy
- **Flat unlock screen** — KeeForge logo → password field → unlock. No database picker on launch
- **Single Keychain entry** — composite key stored keyed by filename only
- **No database metadata** — no names, no last-opened timestamps, no key file associations
- **AutoFill extension** — hardcoded to load the one saved database

## Goals

1. Launch into a **database list** instead of directly into the unlock screen
2. Support **adding, removing, and reordering** multiple databases
3. **Per-database metadata/options**: key file association, quick launch, nickname
4. **Clean Keychain management** — proper per-database credential isolation
5. **Smooth single-database UX** — if only one database is saved, auto-navigate to unlock (or quick-launch with Face ID)
6. **Preserve current AutoFill behavior** — the last successfully unlocked database remains the AutoFill source
7. **Safe upgrade path** — existing users keep their saved database and biometric unlock behavior without silent data loss

---

## Architecture

### New Model: `DatabaseReference`

```swift
struct DatabaseReference: Identifiable, Codable, Hashable {
    let id: UUID                          // Stable ID (persisted)
    var nickname: String?                 // User-defined display name
    var filename: String                  // Original filename (e.g., "work.kdbx")
    var bookmarkData: Data?               // Security-scoped bookmark
    var keyFileBookmarkData: Data?        // Associated key file bookmark
    var keyFileFilename: String?          // Key file display name
    var isQuickLaunch: Bool               // Auto-open on app launch
    var lastOpenedAt: Date?               // Last successful unlock
    var addedAt: Date                     // When added to the list
    var colorTag: String?                 // Optional color label
    var legacyKeychainFilename: String?   // Migration-only: old filename-keyed biometric entry
    
    // Computed
    var displayName: String {
        nickname ?? filename.replacingOccurrences(of: ".kdbx", with: "")
    }
}
```

### Storage: `DatabaseListStore`

Replaces the single-bookmark storage in `SharedVaultStore`. Persists the database list to the App Group container as JSON.

```swift
enum DatabaseListStore {
    /// All registered databases, ordered by user preference
    static var databases: [DatabaseReference] { get set }
    
    /// Add a new database from a file URL
    static func add(url: URL) throws -> DatabaseReference
    
    /// Remove a database (clears bookmark, cache, and Keychain entry)
    static func remove(id: UUID)
    
    /// Update a database reference (nickname, key file, etc.)
    static func update(_ ref: DatabaseReference)
    
    /// Reorder databases
    static func move(from: IndexSet, to: Int)
    
    /// The quick-launch database (if any)
    static var quickLaunchDatabase: DatabaseReference? { get }
    
    // Migration
    static func migrateFromSharedVaultStore()
}
```

**Storage location:** `{AppGroup}/database-list.json`

**Migration requirements:**
- Migration must be **idempotent** and callable from both the main app and the AutoFill extension. The extension may be the first process launched after upgrade.
- On first read, if `database-list.json` does not exist but `SharedVaultStore` still has legacy state, synthesize a single `DatabaseReference` from the saved bookmark, stored filename, and cached-copy metadata.
- Do **not** immediately delete all legacy state. Write the new list first, then keep the legacy filename metadata available until biometric Keychain migration has completed lazily.
- Store a migration version / completion marker so repeated launches do not duplicate the migrated database.

### Shared Database Cache

The shared encrypted database copy is still needed for AutoFill and quick unlock.

- New location: `{AppGroup}/databases/{DatabaseReference.id}.kdbx`
- Cache is per-database, not global
- During migration, if the legacy single cached copy exists, move or copy it into the migrated database's cache slot
- If no cache exists, fallback remains bookmark-based file access until the next successful unlock refreshes the cache

### Keychain Changes

Current: `compositeKey:{filename}` — collides if two databases have the same filename.

New: `compositeKey:{DatabaseReference.id}` — keyed by the stable UUID.

```swift
// KeychainService changes
static func storeCompositeKey(_ key: Data, for databaseID: UUID) throws
static func retrieveCompositeKey(for databaseID: UUID, context: LAContext) throws -> Data
static func deleteCompositeKey(for databaseID: UUID)
static func hasStoredKey(for databaseID: UUID) -> Bool
```

Migration cannot eagerly copy old items on first launch because the existing Keychain entry is biometric-protected.

- Lookup order during migration: UUID-keyed item first, then legacy filename-keyed item if `legacyKeychainFilename` is present
- On successful password unlock, store the freshly derived composite key under the UUID account and clear the legacy filename-based entry
- On successful biometric unlock using the legacy filename-based entry, immediately re-store that same composite key under the UUID account, then clear the legacy entry
- After the UUID-keyed item exists, clear `legacyKeychainFilename` from the database reference

### AutoFill Extension

Currently hardcoded to `SharedVaultStore.loadDatabaseKeychainPath()`. Needs to:
1. Load the database list via the same migration-aware `DatabaseListStore` entry point the main app uses
2. Persist `activeAutoFillDatabaseID` in shared storage whenever a database is successfully unlocked
3. Continue using exactly one AutoFill source database at a time: the last successfully unlocked database
4. The extension loads `activeAutoFillDatabaseID`; if missing, it falls back to the migrated legacy database for upgraded users
5. Credential identities continue to be replaced wholesale from that one database on unlock, matching current behavior
6. Multi-database AutoFill routing is explicitly deferred to a later release

### Settings Model

Current KeeForge settings are all global. v1 multi-database should preserve that unless a value is clearly tied to one specific database.

**Global app settings**
- Auto-Lock Timeout
- Clipboard Clear Timeout
- Auto-Unlock with Face ID / biometrics
- Quick AutoFill enabled
- Download Website Favicons
- Default Sort Order
- Sort Direction
- About / support / tip jar / review-prompt behavior remains app-wide

These map directly to the current app-wide settings storage and should stay global in v1.

**Database-local options / metadata**
- Nickname
- Key file association
- Quick Launch flag
- Color tag

These live on `DatabaseReference` because they describe one database entry in the list, not the app as a whole.

**Database metadata but not user settings**
- `lastOpenedAt`
- `addedAt`
- bookmark data
- cached database copy
- stored biometric composite key presence

These should be treated as persisted state, not editable settings.

**UI structure**
- Keep **one global Settings page** for app-wide preferences
- Do **not** create per-database copies of the current Settings screen
- Database-local options are managed from the database list via context menu actions and, if needed, a lightweight "Database Details" sheet/screen
- In v1, there are not two parallel full settings pages; there is one app Settings page plus per-database management UI

---

## UI Design

### Database List Screen (New Home Screen)

```
┌─────────────────────────────────────┐
│ KeeForge                     [+]    │  ← Add database button
├─────────────────────────────────────┤
│                                     │
│  ┌─────────────────────────────┐    │
│  │ 🔒  Personal               │    │  ← Locked, has Face ID
│  │     personal.kdbx           │    │
│  │     Last opened: 2 hours ago│    │
│  │     🚀 Quick Launch         │    │
│  └─────────────────────────────┘    │
│                                     │
│  ┌─────────────────────────────┐    │
│  │ 🔒  Work                   │    │  ← Locked, has Face ID
│  │     work-passwords.kdbx     │    │
│  │     Last opened: Yesterday  │    │
│  └─────────────────────────────┘    │
│                                     │
│  ┌─────────────────────────────┐    │
│  │ 🔒  Shared Family          │    │  ← Locked, no Face ID
│  │     family.kdbx             │    │
│  │     Key file: family.keyx   │    │
│  │     Last opened: 3 days ago │    │
│  └─────────────────────────────┘    │
│                                     │
└─────────────────────────────────────┘
```

**Each row shows:**
- Lock icon (🔒/🔓) — visual lock state
- Display name (nickname or filename)
- Filename (if nickname differs)
- Last opened relative time
- Quick Launch badge (rocket icon)
- Key file indicator (if associated)
- Face ID indicator (if Keychain entry exists)

**Interactions:**
- **Tap** → navigate to unlock screen for that database
- **Long press / swipe** → context menu: Rename, Set Key File, Toggle Quick Launch, Database Details, Remove
- **[+] button** → file picker to add a new database
- **Edit mode** → reorder and delete
- **Pull to refresh** → re-resolve bookmarks (detect moved/deleted files)

### Single-Database Shortcut

If only one database is registered → still show the list, but auto-navigate to the unlock screen on launch (same as current behavior). If quick-launch is set + Face ID available → go straight to biometric unlock. This is also the post-upgrade behavior for current single-database users after migration.

### Unlock Screen Changes

Minimal changes to `UnlockView`:
- Receives a `DatabaseReference` instead of relying on `SharedVaultStore` globals
- Key file pre-populated if associated in the reference
- "Choose Different File" becomes "Back to Database List" (back navigation)
- After successful unlock, update `lastOpenedAt` on the reference

---

## State Flow

```
App Launch
    │
    ├─ No databases registered → Empty state with "Add Database" button
    │
    ├─ One database, quick launch + Face ID → Auto biometric unlock
    │
    ├─ One database, no quick launch → Show list, user taps to unlock
    │
    └─ Multiple databases → Show list
         │
         ├─ Quick launch database exists → Highlight it, but don't auto-navigate
         │   (user might want a different one)
         │
         └─ User taps database → UnlockView(for: databaseRef)
              │
              ├─ Face ID available → Auto biometric prompt
              │
              └─ Password entry → Unlock → DatabaseNavigationView
                   │
                   └─ Lock (manual or background) → Back to database list
```

### Upgrade / App Update Behavior

App updates are treated as a cold launch, not session restoration.

- iOS replaces the running app process during install, so any in-memory unlocked state is lost
- KeeForge should not attempt to persist or restore `sessionKey`, decrypted entries, navigation state, or search state across upgrade
- On first launch after upgrade, the app starts locked, runs migration if needed, and shows the database list (or the single-database shortcut path)
- If the migrated database is eligible for quick launch + biometrics, the app may immediately show a fresh biometric prompt, but that is a new unlock, not restoration of the prior session

---

## Migration Plan

### Phase 1: Data Layer (no UI changes yet)
1. Create `DatabaseReference` model
2. Create `DatabaseListStore` with JSON persistence
3. Update `KeychainService` to support UUID-keyed entries
4. Add per-database shared cache paths
5. Write idempotent migration logic from `SharedVaultStore` → `DatabaseListStore`
6. Add lazy Keychain migration from filename-keyed entries → UUID-keyed entries
7. Unit tests for all of the above

### Phase 2: Home Screen
1. Create `DatabaseListView` (SwiftUI)
2. Create `DatabaseListViewModel` (`@Observable`)
3. Wire up `KeeForgeApp.swift` to show list → unlock flow
4. Update `UnlockView` to accept `DatabaseReference`
5. Update lock behavior to return to list

### Phase 3: Polish
1. Context menus / database details UI (rename, key file, quick launch)
2. Empty state design
3. Swipe to delete with confirmation
4. Reorder support
5. Bookmark staleness detection + error states
6. AutoFill extension migration to `activeAutoFillDatabaseID`

### Phase 4: Testing
1. Unit tests for DatabaseListStore, migration
2. UI tests for list interactions
3. Test migration from current single-database state
4. Test upgrade when the AutoFill extension is launched before the main app
5. Test legacy biometric unlock before and after lazy Keychain migration
6. Test that opening database B replaces database A as the AutoFill source

---

## Edge Cases

- **Deleted/moved file:** Bookmark resolution fails → show error badge on the row, offer "Relocate" option
- **Duplicate filename:** Two databases named `passwords.kdbx` → Keychain uses UUID, not filename, so no collision
- **iCloud sync conflicts:** Not our problem — Files app handles this. We just re-read the bookmark
- **App Group migration:** `database-list.json` lives in the same App Group, so AutoFill extension can read it
- **Upgrade path:** First launch after update → migrate the saved database into a one-item list, keep the app locked, and preserve legacy biometric unlock until lazy Keychain migration finishes
- **Upgrade while unlocked:** treat as app termination; user must unlock again after update
- **Extension-first launch after upgrade:** extension runs the same migration entry point and must not depend on the main app having launched already
- **AutoFill source switching:** opening database B replaces database A as the AutoFill source; only one database participates at a time in v1
- **Key file bookmark staleness:** Same resolution logic as database bookmarks — refresh if stale

---

## Files to Create/Modify

### New Files
- `KeeForge/Models/DatabaseReference.swift`
- `KeeForge/Services/Persistence/DatabaseListStore.swift`
- `KeeForge/ViewModels/DatabaseListViewModel.swift`
- `KeeForge/Views/DatabaseListView.swift`
- `KeeForge/Views/DatabaseRowView.swift`
- `KeeForgeTests/DatabaseListStoreTests.swift`
- `KeeForgeTests/DatabaseReferenceMigrationTests.swift`
- `KeeForgeTests/KeychainMigrationTests.swift`

### Modified Files
- `KeeForge/App/KeeForgeApp.swift` — new root navigation (list → unlock → browse)
- `KeeForge/Views/UnlockView.swift` — accept DatabaseReference, remove global SharedVaultStore dependency
- `KeeForge/ViewModels/DatabaseViewModel.swift` — accept DatabaseReference for unlock
- `KeeForge/Services/Security/KeychainService.swift` — UUID-keyed composite key storage
- `KeeForge/Services/Persistence/SharedVaultStore.swift` — deprecate (keep for migration), eventually remove
- `AutoFillExtension/CredentialProviderViewController.swift` — load `activeAutoFillDatabaseID` instead of legacy single-database globals
- `KeeForge/Services/AutoFill/CredentialIdentityStoreManager.swift` — preserve single-database replace semantics

### Eventually Remove
- `SharedVaultStore.swift` (after migration period, ~2 versions)

---

## Open Questions

1. **Should locking return to the database list or stay on the unlock screen?** Recommendation: return to list. Matches Strongbox behavior and gives a clean "I'm done with this database" feeling.

2. **Should we support unlocking multiple databases simultaneously?** Not in v1. One unlocked at a time keeps the security model simple (one sessionKey, one credential store).

3. **Should the credential identity store include entries from ALL databases or just the most recently unlocked?** Recommendation: most recently unlocked only for v1. This preserves current behavior and avoids ambiguous QuickType results. Revisit cross-database AutoFill later.

4. **Quick Launch behavior with multiple databases?** Only one can be quick-launch at a time. Setting a new one clears the old one. Similar to Strongbox's rocket icon.

5. **Do we need a second full settings page for databases?** No for v1. Keep one global Settings page and use a smaller per-database details/edit UI from the list.

6. **When can we remove `SharedVaultStore` entirely?** Only after at least one release where both the main app and extension can read migrated state and lazy Keychain migration has had time to complete for upgraded users.

7. **Should AutoFill support multiple databases later?** Probably yes, but only with explicit per-request routing and dedicated UX. It should not block the first multi-database home-screen release.
