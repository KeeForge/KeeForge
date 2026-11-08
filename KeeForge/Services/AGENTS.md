# Services

**Scope:** the integration layer between app logic and the outside world: App Group storage, files and bookmarks, cloud providers, Keychain, system APIs, AutoFill helpers. This file holds the rules that span subfolders; read the subfolder's `AGENTS.md` before changing it.

## Ownership

- `Persistence/DatabaseListStore`: the persisted database list (`DatabaseReference`), cache and backup locations, and the AutoFill database selection. Nothing else writes `database-list.json`.
- `Persistence/LocalDatabaseSaver`: every save whose target is a file on this device, including the AutoFill extension's save into a cloud database's cached copy.
- `Cloud/CloudDatabaseSaver`: the app's save of a cloud-backed database. `Cloud/CloudSyncCoordinator`: download-before-open and conditional sync-down cache publication; the savers own local commits.
- `AutoFill/AutoFillSaveCoordinator`: the extension-safe new-entry workflow and credential identity publication. Its production cloud commit and covering intent are owned by `LocalDatabaseSaver` and the shared upload queue.
- `SSHAgent/MacSSHAgentController`: the macOS-only, opt-in SSH agent that signs with keys stored in the unlocked database (`SSHAgent/AGENTS.md`).
- `Security/KeychainService`: the per-database quick-unlock key. `Cloud/CloudTokenStore`: provider credentials. They are separate items with different protection (see `Security/AGENTS.md`, `Cloud/AGENTS.md`).

## Invariants

### Targets and platforms

- The AutoFill extensions compile only an explicit list of service and view files. `../../project.yml` holds it twice, between the `>>> SHARED AUTOFILL ALLOW-LIST` / `<<< SHARED AUTOFILL ALLOW-LIST` markers under `KeeForgeAutoFill` and `KeeForgeMacAutoFill`. The `- path:` lines must stay identical, in the same order; edit both together or one platform's extension silently diverges.
- A file on that list, and everything it references, must be extension-safe on both platforms: no app-only types or APIs, no dependency on a file that is not also listed, and it must compile for iOS and macOS.
- `KeeForgeMac` compiles the whole `Services` tree except `Cloud/DropboxCloudProvider.swift` and `Cloud/OneDriveCloudProvider.swift`, so every other service must compile on macOS. The iOS app excludes the four `AppSupport/Mac*` files that need AppKit window or hot-key APIs (`MacLockMonitor`, `MacWindowCloseGuard`, `MacQuickAccessController`, `MacGlobalHotKey`) and the `SSHAgent` folder.
- Shared membership means the code compiles on both platforms, not that the feature exists on both. Mac cloud sync offers WebDAV and FTP; Dropbox and OneDrive are iOS-only and not built into the Mac app. Mac AutoFill fills passwords, passkeys, and one-time codes and saves a passkey registration, but has no password save, generation, or picker-created entry (`../../AutoFillExtension/AGENTS.md`).

### Compatibility with shipped installs

- These are read by installs already on devices; do not rename or reshape them: the App Group `group.com.keevault.shared`, the Keychain group `com.keevault.sharedkeychain` and its item naming, stored bookmark data, `database-list.json`, the cache directories (`databases/`, `cloud-cache/`), the backup layout (`Library/Application Support/backups/<database id>/yyyyMMdd-HHmmss-uuuuuu.kdbx`, UTC), and `pending-uploads/<database id>/`.
- All App Group access goes through `Persistence/AppGroupContainer`. What may be written there is in `Persistence/AGENTS.md`.
- `com.keevault.sharedkeychain` stays first in every target's `keychain-access-groups`. Full statement in `Security/AGENTS.md`.
- A persisted type that gains a non-optional field needs a hand-written decoder default. The database list decodes all-or-nothing (a throw shows an empty list) and an undecodable upload marker is skipped, leaving its save uncovered.

### Save paths

- Both savers share one sequence: read the stored bytes, gate on `SaveBaseline`, encrypt, write a timestamped backup of the bytes being replaced, replace, refresh the App Group cached copy, prune backups to the 5 newest (`DatabaseListStore.pruneBackups`). Keep the backup ahead of the replace.
- `SaveBaseline` is the only overwrite gate: stored bytes must hash (SHA-512) to what the session opened, or to the diverged copy a merge already folded into the draft. Anything else returns `.conflict` with the stored bytes; never widen it. `LocalDatabaseSaver` checks the hash again inside its coordinated replace, so a coordinated write that landed while it encrypted conflicts too.
- A local save checks the file itself. A cloud save durably journals immutable ciphertext and commits the cache under that gate before delivery; the drainer verifies exact remote ancestry and the provider guarantee before uploading. Details in `Cloud/AGENTS.md`.
- A rekey or encryption-settings change must reopen the produced bytes with the write key before anything is replaced or uploaded (`SaveError.reencryptionVerificationFailed`). After a rekey upload, a failed local apply is `SaveError.rekeyAppliedRemotely`, because the remote already needs the new key.
- The extension never uploads. Its save of a cloud database goes through `LocalDatabaseSaver` into the cache and leaves a pending-upload marker for the app to drain. The same queue retains immutable pending ciphertext outside cache and backup rotation; legacy markers still require pre-overwrite backups. Marker rules are in `Cloud/AGENTS.md`.
- Mac AutoFill cannot open a bookmarked local file. It saves passkey registrations to the encrypted shared copy and `Persistence/PendingLocalSaveStore`; after the app unlocks the database, `DatabaseViewModel.mergePendingLocalSaves` merges and writes that change to the original file. Pending local saves are separate from cloud upload markers.
- `CloudSyncCoordinator` backs up legacy pending cache bytes before sync-down and retains the actual payload before explicit discard. Confirming an upload never replaces a newer cache. Retained pending/rekey backups are excluded from ordinary backup rotation.
- A save that lands where the cache already is (cloud reference, or a database with no bookmark) must not rewrite the cache a second time; that reopens the window where the cache and its marker disagree.

### Egress and logging

- Network egress is limited to cloud sync, opt-in favicon fetching, and the user-submitted feedback form (root `AGENTS.md`). The extensions make no network requests.
- `AutoFill/AutoFillDiagnostics` (DEBUG builds only) logs event names, flags, and counts, never entry data, URLs, or secrets.

## Tests

- Save paths: `LocalDatabaseSaverTests`, `CloudDatabaseSaverTests`, `CloudSyncCoordinatorTests`, `DatabaseListStoreTests`.
- App Group surface: `AppGroupGuardrailTests`, `AppGroupIsolationTests`.
- AutoFill save and upload markers: `CredentialProviderSaveTests`, `PendingUploadQueueTests`, `PendingUploadDrainerTests`, `PendingUploadRecoveryTests`.
- A change to local, cloud, or AutoFill save behavior also updates `KDBXCompatibilityTests` (`../AGENTS.md`).

## See also

- `AppSupport/AGENTS.md`, `AutoFill/AGENTS.md`, `Cloud/AGENTS.md`, `Persistence/AGENTS.md`, `Security/AGENTS.md`, `SSHAgent/AGENTS.md`
- `../../AutoFillExtension/AGENTS.md`: the extension target and its platform limits
- `../ViewModels/AGENTS.md`: session-side save, conflict, merge, and rekey rules
- `../../KeeForgeMac/SECURITY.md`, `../../docs/threat-model.md`
