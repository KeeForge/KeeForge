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
3. **Per-database settings**: key file association, quick launch, nickname
4. **Clean Keychain management** — proper per-database credential isolation
5. **Smooth single-database UX** — if only one database is saved, auto-navigate to unlock (or quick-launch with Face ID)
6. **AutoFill extension** works across all registered databases

## Non-Goals (for v1)

- Simultaneous multi-database unlock (only one unlocked at a time)
- Cross-database search
- Database creation/editing (still read-only in v1)
- Cloud provider integration beyond what Files app provides

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

**Migration:** On first launch after update, if `SharedVaultStore` has a saved bookmark, automatically create a `DatabaseReference` from it and clear the old storage.

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

Migration: re-key existing entry from filename-based to UUID-based on first launch.

### AutoFill Extension

Currently hardcoded to `SharedVaultStore.loadDatabaseKeychainPath()`. Needs to:
1. Load the database list from `DatabaseListStore`
2. Try to unlock the database that has a stored Keychain entry (for silent QuickType)
3. If multiple databases have stored keys, use the quick-launch one (or most recently opened)
4. For interactive unlock (key icon tap), show a database picker before the password prompt

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
- **Long press / swipe** → context menu: Rename, Set Key File, Toggle Quick Launch, Remove
- **[+] button** → file picker to add a new database
- **Edit mode** → reorder and delete
- **Pull to refresh** → re-resolve bookmarks (detect moved/deleted files)

### Single-Database Shortcut

If only one database is registered → still show the list, but auto-navigate to the unlock screen on launch (same as current behavior). If quick-launch is set + Face ID available → go straight to biometric unlock.

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

---

## Migration Plan

### Phase 1: Data Layer (no UI changes yet)
1. Create `DatabaseReference` model
2. Create `DatabaseListStore` with JSON persistence
3. Update `KeychainService` to support UUID-keyed entries
4. Write migration logic from `SharedVaultStore` → `DatabaseListStore`
5. Unit tests for all of the above

### Phase 2: Home Screen
1. Create `DatabaseListView` (SwiftUI)
2. Create `DatabaseListViewModel` (`@Observable`)
3. Wire up `KeeForgeApp.swift` to show list → unlock flow
4. Update `UnlockView` to accept `DatabaseReference`
5. Update lock behavior to return to list

### Phase 3: Polish
1. Context menus (rename, key file, quick launch)
2. Empty state design
3. Swipe to delete with confirmation
4. Reorder support
5. Bookmark staleness detection + error states
6. AutoFill extension multi-database support

### Phase 4: Testing
1. Unit tests for DatabaseListStore, migration
2. UI tests for list interactions
3. Test migration from current single-database state
4. Test AutoFill with multiple databases

---

## Edge Cases

- **Deleted/moved file:** Bookmark resolution fails → show error badge on the row, offer "Relocate" option
- **Duplicate filename:** Two databases named `passwords.kdbx` → Keychain uses UUID, not filename, so no collision
- **iCloud sync conflicts:** Not our problem — Files app handles this. We just re-read the bookmark
- **App Group migration:** `database-list.json` lives in the same App Group, so AutoFill extension can read it
- **Upgrade path:** First launch after update → migrate seamlessly. User sees their one database in the new list UI
- **Key file bookmark staleness:** Same resolution logic as database bookmarks — refresh if stale

---

## Files to Create/Modify

### New Files
- `KeeForge/Models/DatabaseReference.swift`
- `KeeForge/Services/DatabaseListStore.swift`
- `KeeForge/ViewModels/DatabaseListViewModel.swift`
- `KeeForge/Views/DatabaseListView.swift`
- `KeeForge/Views/DatabaseRowView.swift`
- `KeeForgeTests/DatabaseListStoreTests.swift`
- `KeeForgeTests/DatabaseReferenceMigrationTests.swift`

### Modified Files
- `KeeForge/App/KeeForgeApp.swift` — new root navigation (list → unlock → browse)
- `KeeForge/Views/UnlockView.swift` — accept DatabaseReference, remove global SharedVaultStore dependency
- `KeeForge/ViewModels/DatabaseViewModel.swift` — accept DatabaseReference for unlock
- `KeeForge/Services/KeychainService.swift` — UUID-keyed composite key storage
- `KeeForge/Services/SharedVaultStore.swift` — deprecate (keep for migration), eventually remove
- `AutoFillExtension/CredentialProviderViewController.swift` — multi-database support
- `KeeForge/Services/CredentialIdentityStoreManager.swift` — per-database identity tagging

### Eventually Remove
- `SharedVaultStore.swift` (after migration period, ~2 versions)

---

## Open Questions

1. **Should locking return to the database list or stay on the unlock screen?** Recommendation: return to list. Matches Strongbox behavior and gives a clean "I'm done with this database" feeling.

2. **Should we support unlocking multiple databases simultaneously?** Not in v1. One unlocked at a time keeps the security model simple (one sessionKey, one credential store).

3. **Should the credential identity store include entries from ALL databases or just the most recently unlocked?** Recommendation: all databases that have been unlocked at least once. Populate incrementally — each unlock adds/updates that database's entries. Clear on database removal.

4. **Quick Launch behavior with multiple databases?** Only one can be quick-launch at a time. Setting a new one clears the old one. Similar to Strongbox's rocket icon.
