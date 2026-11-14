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
- Key-file bookmarks on macOS are created and refreshed with `.securityScopeAllowOnlyReadAccess`; database bookmarks retain write access. Resolution accepts both read-only and previously stored writable key-file bookmarks.
- `relinkLocalDatabase(id:to:)` changes only `bookmarkData`, `filename`, `isDocumentsResident`, and `hasUnverifiedRelink`, so the id, key file, Keychain key, AutoFill settings, and backups survive. It refuses a trashed pick and a file another reference already resolves to, and returns nil for cloud and KeeForge-only references, whose cache it would otherwise overwrite.
- A Documents-resident reference (direct child of the iOS app's Documents, never nested) is identified by `Documents/<filename>`, because a Finder replace is delete plus recopy. Only then may a failed or trashed resolution rebind, and only to a file with the KDBX magic that no other resident reference resolves to.
- `rebindBookmarkData` and `rederiveDocumentsIdentity` mutate only their own fields on the stored copy. Never resolve a non-resident bookmark on those paths; it may be a file provider that blocks.
- A missing Documents file never removes its reference. `isDocumentsFileMissing(for:)` is a side-effect-free probe; removal is the user's action.
- `DocumentsVaultScanner` claims only top-level regular files with the 8-byte KDBX magic, so key files and notes dropped beside a database are left alone. It runs off the main thread on iOS scene activation.

### Saves, backups, creation

- After replacing a local database file, a failed refresh of its separate AutoFill cache does not undo the save. `LocalDatabaseSaver` removes the older copy so AutoFill cannot fill stale credentials; if both refresh and removal fail, the saved file remains authoritative and a later unlock or save can refresh the cache.
- `PendingLocalSaveStore` retains each Mac AutoFill save to a bookmarked local database under `pending-local-saves/<database UUID>/`. The extension records the encrypted result before replacing its shared copy; the app merges pending changes into the unlocked session, saves the original file under its baseline check, and removes each pending save only after success. Admit exact receipts durably before invoking the merge saver. Only idle eligible sources can merge after unlock, save, app activation or before rekey; interrupted admission and uncertain outcomes require explicit recovery. A file conflict during rekey must ask for reload; an unmergeable save moves to a retained backup that pruning cannot remove. While pending, cache refresh must not replace the copy AutoFill serves.

- `LocalDatabaseSaver` step order and the `SaveBaseline` gate are in `../AGENTS.md`. Under `-ui-testing` only (`UI_TEST_LOCAL_SAVE_CONFLICT_COUNT`), the saver can rewrite the file with real divergent bytes before the hash check, so UI tests conflict and merge against a real file (`../../../KeeForgeUITests/AGENTS.md`).
- The staged replacement is written outside the picked folder: file-scoped security access may not allow creating a sibling temp file.
- Backups are `yyyyMMdd-HHmmss-uuuuuu.kdbx` in UTC. `recentBackups` and pruning sort by filename, and `DatabaseExportService` parses the date out of it, so any new backup writer must use the same shape.
- Export filenames carry a "KeeForge copy" or "backup" suffix with a timestamp, so exporting into the source folder never overwrites the original.
- Database creation registers the reference only after the durable copy exists (file written, or cloud `createFile` returned), and validates for duplicates before writing. Its verification re-parse runs under `KDFExecutionPolicy.autoFillExtension`, so a new database never exceeds what the extension can open.
- File-provider reads that may never answer go through `CoordinatedFileReader.performBlocking(timeout:)`. The underlying call can still finish later; only the first result is delivered.

- Pending-local sources are immutable: new snapshots use a unique UUID directory and retain the timestamp `.kdbx` filename; legacy flat files remain readable. Receipts bind path, inode and SHA-512. Export and successful merge cleanup use captured receipts, never a mutable cache. A separately confirmed discard touches only its captured snapshot.
- Recovery enumerates each source independently. Export/merge require a SHA-bound receipt; separately confirmed discard may use a readable inode/device/stat/parent proof for an unreadable source or owner record. Unknown or absent proof never authorizes deletion, and a replaced inode fails even when its bytes match. Permanent tombstones are outside all discard snapshots.
- Pending-local ownership uses a stable flock and versioned nonsecret metadata under `pending-local-save-owners/<database UUID>/`, outside the payload tree. Removal permanently revokes writes before list removal and refuses to destroy unresolved sources. List-lock -> flock and coordinated-accessor -> flock remain the owner orders. Local rekey completion snapshots the list briefly, then resolves/coordinates/reads the provider without list lock; inside that accessor it may acquire list only with an immediate try, never a blocking fallback or automatic retry, before owner authorization and the effect. This explicit coord -> try-list exception releases coordination on contention and cannot wait on a list holder that needs those resources. Owner code never acquires the list lock or performs awaits, KDBX parsing or KDF under flock. A retirement failure remains a recovery record, including when its payload is missing. Container resolution and owner decode failures block mutation.
- Durable file/directory helpers live in `CoordinatedFileReader.swift` so staging, backups and the existing cloud marker writer share extension-safe primitives without a cloud queue dependency.
- Durable ancestry is bounded by an explicit existing accessible anchor; reconfirm namespace edges inside that grant on replay, and never fsync the grant's external parent. Payloads and owner files use mode 0600 and, on iOS, complete file protection before file synchronization.

## Tests

- `DatabaseListStoreTests`, `LocalDatabaseSaverTests`, `SharedVaultStoreTests`, `SecurityScopedBookmarkManagerTests`, `DocumentsVaultScannerTests`, `DatabaseCreationServiceTests`, `DatabaseExportServiceTests`.
- `AppGroupGuardrailTests` (write surface) and `AppGroupIsolationTests` (fails if the unit-test redirect stops applying).
- Migration from the single-database storage, including the legacy Keychain filename: `KeychainMigrationTests`.

## See also

- `../AGENTS.md`: save paths, compatibility boundary, allow-list rules
- `../Cloud/AGENTS.md`: cloud cache replacement and upload markers
- `../../../AutoFillExtension/AGENTS.md`: which file the extension opens a database from
- `../../../KeeForgeMac/SECURITY.md`: Mac sandbox and bookmark entitlements

- Local saver outcomes observe replacement effects inside the coordinated accessor, including errors reported after it returns. A committed warning advances installed SHA/key state and ends the invocation; an opaque adapter failure is not proof of no replacement.
- Source publication is provisional intent -> durable ciphertext -> known shared-cache replacement -> typed activation. Preparation alone is never automatic-merge eligibility. Admission, final replacement fencing, exact durable retirement and visible-unconfirmed clear form one production protocol.
- A master-key barrier settles separately from source retirement, only against the installed target and a durable field-specific key-file association receipt. Keep exact target checks while publication is unsettled. Retire the witness only after durable target/association/receipt and owner-epoch certification; replayed ready certificates retire by CAS without a permanent target pin. Reads/exports remain independent.
- Local cache refresh coordinates original/cache before flock and rechecks ciphertext, accepted sources and revocation through publication. A stale completion must not recreate a removed cache.

- Key-change association publication holds combined target/registry coordination before owner flock through the registry write. It rereads reference fields and verifies the compatible installed ciphertext before publishing factors; a later settlement check cannot substitute for that protection.

- Target evidence is one confirmed/unconfirmed/planned state, with a certified ready-to-retire phase. Live completion and recovery share its final transition; planned output cannot inherit the old file’s confirmed durability. Pending preferences retain exact desired-field intent/CAS. Idle selection/renewal uses only field-specific reread/CAS, without permanent target evidence or an owner workflow.

- Every local cache writer captures reference/epoch before external reads and publishes under current-reference lock → original/cache coordination → owner flock. Scanner/initial-copy/heal/relink/migration/creation cannot bypass active recovery or removal; failed publication does not advance scanner fingerprints.

- Ordinary local saves also obtain the existing typed admission with empty source receipts before encryption. Only observed durable completion or affirmative pre-replacement proof releases it; unknown, warning or interrupted outcomes keep recovery and block subsequent automatic encryption across sessions. Database-bookmark renewal updates only the expected bookmark under reference/epoch CAS, never a captured whole reference. Primary-target resolution is shared by replacement and witness retirement, including KeeForge-only cache targets.

- An empty ordinary admission may retain its known typed TargetCommit. Only an exact same-epoch baseline/identity permits a fresh explicit operation; unknown outcomes and receipt-bearing admissions never use that path. Cache effects use only its known bytes or the live matching commit receipt, preserving source ownership. A failed pre-replacement release is observable and cannot promise a safe retry.

- A new ordinary attempt keeps one flat preceding known-commit proof for affirmative pre-replacement unwind. Restoring it preserves the previous uncertainty; a newer unknown attempt never inherits its retry permission. Successful known publication replaces that proof rather than growing a history chain.

- Initial admission returns its token when publication was observed but durability/coordination was unconfirmed; callers must surface terminal recovery before crypto. Rekey Keychain effects run off MainActor with combined target/registry coordination, immediate try-list and owner locks held through the effect. Provider resolution and complete ciphertext reads happen before try-list. A per-attempt RAM permit closes pending authority on timeout/cancel or a subsequent lock/new session; once claimed, interruption cannot imply no effects or release held resources. Worker callbacks and legacy cleanup never call MainActor synchronously. Verify current target identity and exact ciphertext against that receipt even after witness retirement; epoch or inode equality alone is insufficient. This completion check must not constrain fresh restored-file reads after retirement. Creation passes its already-authenticated ciphertext to the single session RAM context for pre-first-save draft export.

- The optional interruption callback on blocking reads runs before timeout/cancel is delivered. It does not stop the underlying IO or prove no effects; mutation callers must revoke pending permission at the real effect boundary and keep committed ownership until affirmative completion/recovery. Read callers without that callback keep their existing cancellation behavior.

- Successful reference removal and list clear delete quick-unlock master-entry dates only through the security owner’s process-wide leaf lock. Do not mutate its shared-defaults dictionary directly or acquire list/owner from that date lock. Shared UserDefaults still has no cross-process date transaction guarantee.
