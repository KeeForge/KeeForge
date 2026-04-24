# Database Creation - Spec

## Summary

Add support for creating a brand-new KeePass database from inside KeeForge. The v1 path creates a local KDBX 4.x database in KeeForge-owned app-group storage, adds it to the database list, and opens it immediately as an unlocked session so the user can add entries without going through a second unlock step.

This is a local-first feature. The created database is fully compatible with the existing local save, backup, AutoFill cache, biometric composite-key storage, and multi-database list flows. Creating a new Dropbox file directly is deferred.

## Current State

- KeeForge can add existing local files through a security-scoped bookmark.
- KeeForge can add existing Dropbox files through the cloud browser.
- `KDBXWriter` already has `FreshHeaderConfiguration`, which can produce a KDBX 4.x file without reusing an existing header.
- `LocalDatabaseSaver` can save a local `DatabaseReference` with no bookmark by falling back to `DatabaseListStore.cacheLocation(for:)`.
- `DatabaseListStore` has no API for registering an app-created database before there is an external file URL.
- There is no UI or service that builds a minimal empty KeePass tree, creates fresh KDF/header material, writes encrypted bytes, and starts an unlocked database session.

## Goals

1. Let users create a new password database from the database list.
2. Produce a valid KDBX 4.x file that KeeForge can reopen and that opens in KeePass-compatible clients.
3. Keep all crypto, KDF, compression, serialization, and file writes off the main actor.
4. Store no raw master password after creation. Persist only the composite key through the existing biometric Keychain path when available.
5. Make the created database available to AutoFill after the first successful creation/open, matching the existing "last opened database" behavior.
6. Use the existing draft/save pipeline for the first and subsequent edits.

## Non-Goals

- Creating KDBX 3.1 databases.
- Creating a new Dropbox/cloud file in v1.
- Changing a database's master password, key file, cipher, or KDF after creation.
- Generating new key files.
- Importing templates or sample entries.
- Exporting or relocating app-created databases to Files. A later slice can add "Export Copy" or "Move to Files".

## Product Decisions

### Storage

v1 creates databases inside KeeForge-owned app-group storage:

- `DatabaseReference.source = .local`
- `bookmarkData = nil`
- encrypted bytes live at `DatabaseListStore.cacheLocation(for: reference)`
- the displayed filename still ends in `.kdbx`

This intentionally uses the path that `LocalDatabaseSaver.resolveLocation(for:)` already supports for app-owned databases with no security-scoped bookmark. Removing the database from KeeForge deletes the cached database file, saved composite key, backups, and pending upload markers just like existing references.

### Creation Flow

The database list `+` menu gains a new first action:

- `New Database`
- `Local Device`
- `Dropbox`

`New Database` presents a SwiftUI creation sheet with:

- database name
- master password
- confirm master password
- optional existing key file picker
- create button

Validation:

- database name must normalize to a non-empty `.kdbx` filename
- filename must not duplicate another app-created local database filename
- password confirmation must match
- at least one key component is required: password, key file, or both
- weak passwords should show a warning, but v1 should not invent complex composition rules

After success, the sheet clears password fields, dismisses, reloads the database list, and opens the new database unlocked.

### Format Defaults

New databases should use conservative, widely compatible defaults:

- File format: KDBX 4.x using the existing writer minor version
- Outer cipher: AES-256-CBC (`KDBXParser.aesCipherUUID`)
- Compression: gzip
- KDF: Argon2id
- Argon2id parameters:
  - `I`: `UInt64(3)`
  - `M`: `UInt64(64 * 1024 * 1024)` bytes
  - `P`: `UInt32(1)`
  - `V`: `UInt32(0x13)`
  - `S`: 32 bytes from `SecRandomCopyBytes`
- Inner protected-value stream: ChaCha20 (`KDBXParser.innerStreamChaCha20`)
- Inner stream key: 64 bytes from `SecRandomCopyBytes`

Centralize these values in one creation-defaults helper so tests assert the exact defaults and future tuning is deliberate.

## Data Model

### Creation Request

Add a small request model in the creation service layer:

```swift
struct DatabaseCreationRequest: Sendable {
    var displayName: String
    var password: String?
    var keyFileData: Data?
    var keyFileBookmarkData: Data?
    var keyFileFilename: String?
}
```

The raw password should stay in the view model only long enough to derive the composite key. The service should accept `String?` because the current unlock flow already does, but it should immediately derive the composite key inside the off-main creation task.

### Created Database Result

```swift
struct CreatedDatabase: Sendable {
    let reference: DatabaseReference
    let rootGroup: KPGroup
    let meta: KPMeta
    let formatVersion: KDBXParser.FileVersion
    let sessionKey: SymmetricKey
    let compositeKey: Data
    let openTimeSHA512: Data
}
```

This mirrors `DatabaseViewModel.ReloadedDatabase` and lets the app enter an unlocked session without re-reading and re-parsing the file on the main actor.

### Fresh KeePass Tree

Create a minimal, useful tree:

```swift
let recycleBinID = UUID()
let visibleRoot = KPGroup(
    name: displayName,
    iconID: 48,
    groups: [
        KPGroup(
            id: recycleBinID,
            name: "Recycle Bin",
            iconID: 43,
            isExpanded: false,
            creationTime: now,
            lastModificationTime: now
        )
    ],
    creationTime: now,
    lastModificationTime: now
)
let root = KPGroup(name: "Root", groups: [visibleRoot])
let meta = KPMeta(
    recycleBinUUID: recycleBinID,
    hasRecycleBinUUIDElement: true,
    maintenanceHistoryDays: KPMeta.defaultMaintenanceHistoryDays,
    historyMaxItems: KPMeta.defaultHistoryMaxItems,
    historyMaxSize: KPMeta.defaultHistoryMaxSize
)
```

KeeForge's parser uses a synthetic wrapper group named `Root`, while the visible vault root is the single child group. Building the tree in that shape keeps `DatabaseViewModel.visibleRootGroupID` behavior unchanged.

### Creation Metadata

Fresh files should not rely on opaque XML fragments for metadata KeeForge intentionally writes. Add focused `KPMeta` fields only if needed for compatibility with KeePassXC/manual testing:

- `generator`
- `databaseName`
- `databaseNameChanged`
- `recycleBinEnabled`
- `recycleBinChanged`

Existing databases already preserve these through `unknownXML`; this addition is for creating clean first-party metadata, not for broad metadata editing.

## Services

### `DatabaseCreationService`

Add `KeeForge/Services/Persistence/DatabaseCreationService.swift`.

Responsibilities:

1. Validate and normalize the request.
2. Create a `DatabaseReference` with a fresh UUID, `.local` source, no bookmark, optional key-file bookmark metadata, `isReadOnly = false`, and `addedAt = now`.
3. Build the empty KeePass tree and metadata.
4. Derive the composite key from password/key-file data.
5. Build fresh header configuration with secure random KDF salt.
6. Call `KDBXWriter.write(rootGroup:meta:compositeKey:freshHeader:sessionKey:)`.
7. Parse the generated bytes once in the same detached task to prove the file reopens.
8. Call `DatabaseListStore.addCreatedLocal(_:, encryptedBytes:)` to write the encrypted bytes and append the reference.
9. Return `CreatedDatabase`.

Register the database only after the encrypted bytes have been generated and re-parsed successfully. `DatabaseListStore.addCreatedLocal` must write the file before appending the reference, so a write failure leaves no broken row behind.

### `DatabaseListStore`

Add a narrow registration API for app-created databases:

```swift
static func addCreatedLocal(_ reference: DatabaseReference, encryptedBytes: Data) throws
```

This method should:

- reject duplicate app-created filenames
- create the cache parent directory
- write the encrypted bytes to `cacheLocation(for:)`
- append the reference to `database-list.json`

Do not use `SecurityScopedBookmarkManager` for app-created storage.

### Randomness

Add one shared helper for security-sensitive random bytes:

```swift
enum SecureRandom {
    static func data(count: Int) throws -> Data
}
```

Use `SecRandomCopyBytes`, and update `KDBXWriter` fresh-header generation to use it instead of `SystemRandomNumberGenerator`. Fresh master seeds, IVs, KDF salts, and inner stream keys are database security boundaries.

## View Models

### `DatabaseCreationViewModel`

New `@MainActor @Observable` type that owns only form state and the async create operation:

- `databaseName`
- `password`
- `confirmPassword`
- `keyFileData`
- `keyFileFilename`
- `isCreating`
- `validationError`
- `creationError`

It should expose:

```swift
func selectKeyFile(url: URL) throws
func clearKeyFile()
func create() async -> CreatedDatabase?
func clearSecrets()
```

The key file picker should store bookmark data on the request when selected, matching the existing database-details key-file association behavior.

### `DatabaseViewModel`

Add a creation bootstrap path, preferably an initializer or factory:

```swift
init(createdDatabase: CreatedDatabase)
```

This initializer should set the same state that `finalizeSuccessfulUnlock(...)` sets today:

- `state = .unlocked`
- `rootGroup`, `unlockedMeta`, `openedFormatVersion`
- `compositeKey`, `sessionKey`, `openTimeSHA512`
- initial group selection
- inactivity timer
- biometric composite-key storage
- `DatabaseListStore.markDatabaseOpened(id:)`
- credential identity store population

Keep this path private to the main app. The AutoFill extension does not create databases in v1.

## UI

### Database List

Modify `DatabaseListView`:

- Add `New Database` to `addDatabaseMenuContent`.
- Present `DatabaseCreationView` as a sheet.
- On creation success, call a new `onCreateDatabase(CreatedDatabase)` callback or reuse the existing `onSelectDatabase` path through a created-session factory.
- Reload `DatabaseListViewModel` after creation.

Accessibility identifiers:

- `database.add.new`
- `database-create.name-field`
- `database-create.password-field`
- `database-create.confirm-password-field`
- `database-create.keyfile.select`
- `database-create.keyfile.clear`
- `database-create.create-button`
- `database-create.cancel-button`
- `database-create.error`

### App Root

`AppRootView` should open the returned `CreatedDatabase` directly:

- compact layout: dismiss creation sheet and show the newly unlocked vault
- regular layout: keep the database list visible and render the unlocked workspace in the detail column

The new database should become the active AutoFill database because creation counts as a successful open.

## Security

- Do not log database names together with errors that include file paths or crypto failures.
- Do not log passwords, key-file bytes, composite keys, KDF salts, seeds, or generated headers.
- Clear creation form password fields on cancel, failure retry, and success.
- Keep password and key-file data out of `DatabaseReference` and App Group JSON.
- Use complete file protection for created encrypted bytes.
- Wrap the creation write in a background task named `DatabaseCreation`.
- All serialization, KDF work, SHA512, and validation parse should run in `Task.detached(priority: .utility)`.
- If app backgrounding interrupts the UI, the service should either complete the atomic write or leave no registered database row.

## Error Handling

Surface user-friendly errors for:

- duplicate database name
- invalid or empty name
- password confirmation mismatch
- missing password/key-file combination
- key file bookmark/read failure
- KDF parameter failure
- encrypted file write failure
- generated file failed to re-open

Creation errors should leave the sheet open with fields intact except after explicit cancel. Success clears secrets before dismissal.

## Testing

### Unit

Add `KeeForgeTests/DatabaseCreationServiceTests.swift`:

- `testCreatePasswordOnlyDatabaseWritesParseableKDBX4`
- `testCreatePasswordAndKeyFileDatabaseReopensWithCompositeKey`
- `testCreateDatabaseBuildsSingleVisibleRootAndRecycleBin`
- `testCreateDatabaseUsesExpectedKDFDefaults`
- `testCreateDatabaseGeneratesFreshSaltAndHeaderMaterialEachTime`
- `testCreateDatabaseDoesNotRegisterReferenceWhenWriteFails`
- `testCreateDatabaseRejectsDuplicateAppCreatedFilename`
- `testCreateDatabaseSanitizesFilenameAndAppendsKDBXExtension`
- `testCreatedEncryptedBytesDoNotContainVisibleRootName`

Add focused writer coverage:

- `KDBXWriterTests.testWriteFreshEmptyDatabaseRoundTrips`

Add store coverage:

- `DatabaseListStoreTests.testAddCreatedLocalPersistsReferenceAndCache`
- `DatabaseListStoreTests.testRemoveCreatedLocalDeletesCacheAndBackups`

Add view-model coverage:

- `DatabaseViewModelTests.testCreatedDatabaseInitializerStartsUnlocked`
- `DatabaseViewModelTests.testCreatedDatabaseCanSaveFirstEntry`
- `DatabaseListViewModelTests.testReloadIncludesCreatedDatabase`

### UI

Add one small XCUITest class only if the implementation adds enough accessible surface to make it stable:

- create database from empty list
- verify unlocked vault appears
- add first entry
- save
- lock and reopen with the chosen password

Do not run the full UI suite for this slice.

### Manual

- Create a password-only database, add an entry, save, lock, reopen.
- Create a password-plus-key-file database, save, lock, reopen with the associated key file.
- Create on iPhone compact layout and iPad regular-width layout.
- Export a created `.kdbx` manually from the simulator container and open it in KeePassXC.
- Confirm AutoFill sees the created database after the first successful open.

Suggested focused command:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseCreationServiceTests -quiet
```

## Rollout Slices

### Slice 01: Format and Service

- Add `SecureRandom`.
- Add creation defaults.
- Add `DatabaseCreationService`.
- Add `DatabaseListStore.addCreatedLocal`.
- Add fresh empty-database writer tests.

### Slice 02: Created Session Bootstrap

- Add `DatabaseViewModel` created-database initializer/factory.
- Persist biometric composite key and mark the database opened through the same path as unlock.
- Add unit tests for created session state and first save.

### Slice 03: Main App UI

- Add `DatabaseCreationViewModel`.
- Add `DatabaseCreationView`.
- Wire the database list `New Database` action.
- Verify compact and regular-width behavior.

### Slice 04: Compatibility Polish

- Add any structured `KPMeta` fields required by KeePassXC/manual compatibility.
- Add manual KeePassXC verification notes to the PR.
- Add a small UI test if the flow is stable enough.

## Exit Criteria

- [ ] A newly created database reopens in KeeForge with password-only credentials.
- [ ] A newly created database reopens in KeeForge with password plus an associated key file.
- [ ] The first save after creation uses the existing local save path and creates backups on subsequent saves.
- [ ] Created databases appear in the multi-database list and can be removed cleanly.
- [ ] Created databases become the active AutoFill source after creation/open.
- [ ] No force unwraps outside tests.
- [ ] KDF, encryption, parsing, SHA512, and file writes do not run on the main actor.
- [ ] Fresh cryptographic bytes come from `SecRandomCopyBytes`.
- [ ] `xcodegen generate` is run if new source files are added to `project.yml`.
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG Entry

`- Added support for creating new local KDBX 4.x databases from KeeForge.`
