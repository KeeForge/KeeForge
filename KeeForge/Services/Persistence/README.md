# Persistence Services

This folder owns database references, cached copies, file access, and local-save infrastructure.

## Main Files

- `DatabaseListStore.swift` persists known databases, quick-launch state, active AutoFill selection, backup locations, read-only flags, and edit acknowledgments.
- `DatabaseCreationService.swift` prepares new KDBX databases and registers local or cloud-created references after the durable copy is available.
- `LocalDatabaseSaver.swift` handles atomic local saves, open-time conflict detection, backup rotation, and shared-cache refresh.
- `SharedVaultStore.swift` reads and writes the shared cached database copy used by the app and AutoFill extension.
- `SecurityScopedBookmarkManager.swift` and `CoordinatedFileReader.swift` handle bookmark resolution and coordinated file access.
- `DocumentPickerService.swift`, `KeyFileProcessor.swift`, and `SyncedFolderDetector.swift` cover file picking, key-file parsing, and synced-folder classification.

## Change Carefully

- App Group paths, bookmark payloads, backup directory layout, and cached-copy semantics are compatibility boundaries.
- If you move persistence behavior across app and extension boundaries, update `../../../project.yml` and `../../../AutoFillExtension/README.md` in the same change.
