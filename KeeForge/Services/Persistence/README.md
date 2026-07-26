# Persistence Services

This folder owns database references, cached copies, file access, and local-save infrastructure.

## Main Files

- `DatabaseListStore.swift` persists known databases, quick-launch state, active AutoFill selection, backup locations, read-only flags, and edit acknowledgments.
- `DatabaseCreationService.swift` prepares new KDBX databases and registers local or cloud-created references after the durable copy is available.
- `LocalDatabaseSaver.swift` handles atomic local saves, open-time conflict detection, backup rotation (timestamped backups, pruned via `DatabaseListStore.pruneBackups` to keep the 5 newest), and shared-cache refresh. The refresh is skipped when the resolved save location already is the shared cache file (cloud references without a bookmark, e.g. AutoFill-extension saves) — the atomic replace is the cache write there.
- `SharedVaultStore.swift` owns the App Group cache directory paths and reads of the shared cached database copy for the app and AutoFill extension. Production cache *writes* go through `DatabaseListStore.cacheDatabaseCopy(_:for:)` (callers: `LocalDatabaseSaver`, `CloudSyncCoordinator`, `DatabaseCreationService`, `DatabaseViewModel`); `SharedVaultStore.cacheDatabaseCopy(_:sourceURL:)` is legacy, called only by tests.
- `DatabaseFileInfoLoader.swift` reads file size, modification date, and the plaintext KDBX header summary for the Database Details sheet without unlocking — local references resolve their bookmark; cloud-backed references use the cached copy.
- `SecurityScopedBookmarkManager.swift` and `CoordinatedFileReader.swift` handle bookmark resolution and coordinated file access. Bookmarks track file identity, so a Files-app Delete or Replace leaves them resolving to the old copy in Recently Deleted; `DatabaseListStore.locateDatabaseFile(for:)` classifies that as `.inTrash` and every database read/save path treats it as unavailable instead of silently using the stale copy.
- `DocumentPickerService.swift`, `KeyFileProcessor.swift`, and `SyncedFolderDetector.swift` cover file picking, key-file parsing, and synced-folder classification.

## Change Carefully

- App Group paths, bookmark payloads, backup directory layout, and cached-copy semantics are compatibility boundaries.
- If you move persistence behavior across app and extension boundaries, update `../../../project.yml` and `../../../AutoFillExtension/README.md` in the same change.

## App Group Guardrail (macOS)

- The App Group container `group.com.keevault.shared` is user-world-readable on macOS 14 (unlike iOS, where the container is inside the app sandbox).
- Standing rule: only encrypted KDBX payloads, security-scoped bookmark blobs, and filename metadata may be written to the group container (files or the shared `UserDefaults` suite) — never key material, master passwords, session keys, or decrypted content.
- `KeeForgeTests/AppGroupGuardrailTests.swift` pins `SharedVaultStore`'s write surface to that shape; extend it whenever new writes to the group container are added.
- `SecurityScopedBookmarkManager.swift` uses `.withSecurityScope` for both bookmark creation and resolution on macOS (plain bookmarks grant no sandbox access across relaunch there); iOS keeps `options: []`. Resolution falls back to a plain resolve on macOS for older bookmark data.
