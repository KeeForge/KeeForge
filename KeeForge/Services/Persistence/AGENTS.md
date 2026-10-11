# Persistence Services

**Scope:** the database list, the App Group container, cached copies and backups, bookmark and file access, local saves, database creation and export. The save-path split and the on-disk compatibility boundary are in `../AGENTS.md`.

## Ownership

- `AppGroupContainer`: the only resolver of the App Group directory and the shared `UserDefaults` suite.
- `DatabaseListStore`: source of truth for known databases and everything derived from a `DatabaseReference`: where its file, cache, and backups are, which database AutoFill uses, and the consequences of removing a database or turning its AutoFill off.
- `DatabaseListStore.locateDatabaseFile(for:)`: the one place a local bookmark is resolved, classified, refreshed, or healed. `DatabaseFileAccess` is the reader built on it (cloud references read the cached copy).
- `LocalDatabaseSaver`: local saves; also declares `SaveBaseline`, `EncryptionSettingsChange`, and `SaveError`, which `../Cloud/CloudDatabaseSaver` shares.
- `SharedVaultStore`: the cache directory paths and the pre-list single-database storage that `DatabaseListStore` migrates from. Its `cacheDatabaseCopy(_:sourceURL:)` is legacy and called only by tests; production cache writes go through `DatabaseListStore.cacheDatabaseCopy(_:for:)`.

## Invariants

### App Group container

- Resolve shared storage through `AppGroupContainer.url` / `.defaults`. Never call `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` or `UserDefaults(suiteName:)` anywhere else.
- Reason: `KeeForgeMacTests` is hosted by the real signed Mac app, so an unredirected unit test operates on the developer's own container, and `DatabaseListStore.clearAll()` in `setUp` deletes the list, backups, and upload markers. `AppGroupContainer` redirects both when `XCTestConfigurationFilePath` is set (unit-test hosts only; a UI test's app keeps the real container so the extension process can share it).
- Never write key material, master passwords, session keys, or decrypted vault content to the container or the shared suite. Database bytes there are always the encrypted KDBX payload, written `.atomicProtected`.
- Keep the container to what the app and extension actually share. Plaintext metadata only the app needs belongs in the app sandbox; on macOS that already applies to cloud account records (`SharedVaultStore.cloudAccountDefaults`) and the favicon cache.
- `AppGroupGuardrailTests` pins `SharedVaultStore`'s write surface (cache directories under the container, only `.kdbx` payloads cached unchanged, only a bookmark blob and filename in defaults). Extend it when adding a writer to the container.
- `AppGroupContainer.url` absorbs a denied group into a temporary directory. Only `resolvedURL` reports the denial, and only `../AppSupport/MacTransitionNoticeService` should need it.

### Database list

- Mutate the list through `DatabaseListStore`'s methods, which serialize under one lock. A field-specific setter rereads the stored reference first; a new one must too, or it rolls back a concurrent change to another field.
- Code that learns cloud state across an `await` writes it with `updateCloudSyncMetadata(for:ifUnchangedFrom:mutate:)`, never `update(_:)` (`../Cloud/AGENTS.md`).
- `remove(id:)` owns removal: Keychain item, cached copy, backups, upload markers, AutoFill pointer, and the database's published identities. `setAutoFillEnabled` owns the same for disabling. Do not repeat parts of either elsewhere.
- A database with AutoFill disabled can never be `activeAutoFillDatabaseID` or `defaultAutoFillDatabase`; the setter refuses it.
- A cloud reference's cache path derives from provider, account, and a hash of the file id (`cacheLocation(for:)`). Local references use `databases/<id>.kdbx`. For a KeeForge-only database (no bookmark, not cloud) that file is the database itself, not a copy.

### Bookmarks and file identity

- Bookmarks follow file identity. After a Files-app Delete or Replace the bookmark still resolves, to the old copy in the trash. `locateDatabaseFile(for:)` reports it as `.inTrash`; no path may read, write, cache, or re-bookmark that copy.
- macOS creates and resolves bookmarks with `.withSecurityScope` (a plain bookmark grants no access after relaunch, and fails silently); iOS uses no options. The macOS plain-resolve fallback exists for bookmark data stored without the option.
- `relinkLocalDatabase(id:to:)` changes only `bookmarkData`, `filename`, `isDocumentsResident`, and `hasUnverifiedRelink`, so the id, key file, Keychain key, AutoFill settings, and backups survive. It refuses a trashed pick and a file another reference already resolves to, and returns nil for cloud and KeeForge-only references, whose cache it would otherwise overwrite.
- A Documents-resident reference (direct child of the iOS app's Documents, never nested) is identified by `Documents/<filename>`, because a Finder replace is delete plus recopy. Only then may a failed or trashed resolution rebind, and only to a file with the KDBX magic that no other resident reference resolves to.
- `rebindBookmarkData` and `rederiveDocumentsIdentity` mutate only their own fields on the stored copy. Never resolve a non-resident bookmark on those paths; it may be a file provider that blocks.
- A missing Documents file never removes its reference. `isDocumentsFileMissing(for:)` is a side-effect-free probe; removal is the user's action.
- `DocumentsVaultScanner` claims only top-level regular files with the 8-byte KDBX magic, so key files and notes dropped beside a database are left alone. It runs off the main thread on iOS scene activation.

### Saves, backups, creation

- `LocalDatabaseSaver` step order and the `SaveBaseline` gate are in `../AGENTS.md`. Under `-ui-testing` only (`UI_TEST_LOCAL_SAVE_CONFLICT_COUNT`), the saver can rewrite the file with real divergent bytes before the hash check, so UI tests conflict and merge against a real file (`../../../KeeForgeUITests/AGENTS.md`).
- The staged replacement is written outside the picked folder: file-scoped security access may not allow creating a sibling temp file.
- Backups are `yyyyMMdd-HHmmss-uuuuuu.kdbx` in UTC. `recentBackups` and pruning sort by filename, and `DatabaseExportService` parses the date out of it, so any new backup writer must use the same shape.
- Export filenames carry a "KeeForge copy" or "backup" suffix with a timestamp, so exporting into the source folder never overwrites the original.
- Database creation registers the reference only after the durable copy exists (file written, or cloud `createFile` returned), and validates for duplicates before writing. Its verification re-parse runs under `KDFExecutionPolicy.autoFillExtension`, so a new database never exceeds what the extension can open.
- File-provider reads that may never answer go through `CoordinatedFileReader.performBlocking(timeout:)`. The underlying call can still finish later; only the first result is delivered.

## Tests

- `DatabaseListStoreTests`, `LocalDatabaseSaverTests`, `SharedVaultStoreTests`, `SecurityScopedBookmarkManagerTests`, `DocumentsVaultScannerTests`, `DatabaseCreationServiceTests`, `DatabaseExportServiceTests`.
- `AppGroupGuardrailTests` (write surface) and `AppGroupIsolationTests` (fails if the unit-test redirect stops applying).
- Migration from the single-database storage, including the legacy Keychain filename: `KeychainMigrationTests`.

## See also

- `../AGENTS.md`: save paths, compatibility boundary, allow-list rules
- `../Cloud/AGENTS.md`: cloud cache replacement and upload markers
- `../../../AutoFillExtension/AGENTS.md`: which file the extension opens a database from
- `../../../KeeForgeMac/SECURITY.md`: Mac sandbox and bookmark entitlements
