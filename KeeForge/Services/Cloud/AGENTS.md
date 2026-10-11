# Cloud Services

**Scope:** the provider abstraction, the cloud-backed open and save pipeline, and the pending-upload queue that carries an AutoFill save to the remote. The shared save sequence and `SaveBaseline` are in `../AGENTS.md`.

## Ownership

- `CloudProvider` is the only boundary the rest of the app talks to; SDK and protocol behavior stays behind it. `CloudProviderRegistry.provider(for:)` resolves one, including the UI-test doubles.
- `CloudSyncModels`: the persisted shapes. Concurrency uses one opaque `rev`; each provider maps its own validator onto it (Dropbox rev, OneDrive cTag/eTag, WebDAV ETag, FTP `sha256:` of the bytes).
- `CloudDatabaseSaver.remoteHasDiverged`: the single conflict gate for both the app save and a pending-upload push.
- `CloudSyncCoordinator`: when an open contacts the provider, and every replacement of a cloud cache file (`downloadLatestCopy`, `applyUploadedBytesAfterSave`).
- `PendingUploadQueue` (compiled into the extensions): marker storage. `PendingUploadDrainer` (app only): the only uploader of markers. Draining goes through `DatabaseListViewModel.drainPendingUploadsOnAppActive()`; the second instance `KeeForgeApp` holds only observes the AutoFill notification. `PendingUploadRecovery`: finds a conflicted marker's bytes for a merge.

## Invariants

### Platform scope

- iOS offers Dropbox, OneDrive, WebDAV, and FTP. The Mac app offers WebDAV and FTP only (`CloudProviderKind.isAvailableOnCurrentPlatform`).
- Dropbox and OneDrive are not built into the Mac app: both provider files are excluded from `KeeForgeMac` in `../../../project.yml`, `SwiftyDropbox` and `MSAL` are off that target (MSAL is an embedded framework that ships whole), `provider(for:)` returns nil for them, and `handleOpenURL` returns false. The macOS branches inside those two files are uncompiled and untested.
- Re-enabling either means restoring its source, package, URL scheme and Info.plist keys (`DropboxAppKey`, `OneDriveClientID`, `OneDriveRedirectURI`) together, plus for OneDrive the MSAL keychain group, then regenerating the Developer ID profiles.

### Provider contract

- `createFile` is create-only on every provider and must never replace an existing file; database creation and conflict copies depend on it. It must not filter by extension either: a conflict copy keeps the database's own extension.
- `listFiles` filters through `CloudFile.isListed`. Dropbox's server-side search filter must be dropped when `includesAllFiles` is set. FTP never lists its own scratch files (`isScratchName`): one opened as a database could later be swept.
- `download` returns the metadata of the bytes it wrote, or nil when the transport cannot say. Record that in preference to the earlier `getMetadata` reading, which goes stale if someone writes mid-transfer.
- An upload response may omit rev or hash. Never overwrite a recorded value with nil, or every later save falls into the weaker nil-rev gate.
- A provider whose `getMetadata` must transfer the file sets `metadataProbeTransfersContent` (FTP), which exempts it from the open-probe deadline.

### Conflict verification

- A missing `expectedRev` must never skip `remoteHasDiverged`. The upload then goes out unconditionally (Dropbox overwrite, OneDrive replace), so the metadata check is the only protection: it compares content hashes, and if the remote reports no hash any remote rev counts as divergence. Only a provider exposing neither is unverified.
- The app save rebases instead of conflicting only when the remote bytes hash to a state `SaveBaseline` covers, at the divergence gate and after a provider 412, with exactly one retry. The retry's rev is read before the byte check so an edit in between fails `If-Match`. Bytes that differ always conflict.
- The pending-upload push uses the plain gate; it has no baseline.
- The backup is written before the upload, so a local failure cannot leave the remote advanced and the save reported as failed.
- Known residue, not hidden: WebDAV sends `If-Match` only for strong ETags; a OneDrive upload session (over 4 MiB) checks it at session creation, not commit; FTP has no conditional write. Read the site comment before attempting a fix.

### Opening and cache replacement

- `syncIfNeededForOpen` under `CloudSyncPolicy.manual` returns the cache without resolving a provider, unless no cache exists. Explicit requests pass `honorsManualSyncPolicy: false`. The policy only gates checking: saves and drains still upload, and the save's gate catches a remote that moved meanwhile.
- The metadata probe races `openProbeDeadline` only when a cache can stand in; a miss is treated as offline. With no cache it waits out the transport.
- `downloadLatestCopy` pins the existing cache with a hard link before the transfer and before listing markers, then publishes with a coordinated replace conditioned on the pinned inode. A save that lands mid-download then makes the sync fall back to the cache instead of reverting it.
- Do not move the pin after the download (it would pin the newer save and replace it), and do not use a rename-aside (the cache path would be empty during the transfer).
- When a marker is queued, both cache-replacing paths back the cache up into the database's backup directory first (`applyUploadedBytesAfterSave` only when the cache differs from the bytes being applied). A failed backup aborts the replacement: losing the only copy of an unuploaded save is worse than a failed refresh.
- Cloud state learned across an `await` is written with `DatabaseListStore.updateCloudSyncMetadata(for:ifUnchangedFrom:mutate:)`, not `update(_:)`, which would roll back a save or drain that finished inside the window.

### Pending-upload markers

- Invariant: cache bytes that have not been uploaded always have a durable marker covering them. Markers are fsynced, hold no secrets, and store the cache path relative to the App Group container, because the extension returns before the app runs.
- Created only by `AutoFillSaveCoordinator.saveNewEntry`, in two phases whose order is load-bearing: a provisional marker with the base bytes' SHA-512 (`isPayloadFinalized: false`, no Darwin notification), then the cache write, then `finalize` with the payload hash and the notification. Re-derive the crash analysis at that call site before reordering.
- `isPayloadFinalized` is tri-state. `false` is provisional; `nil` is a marker from before the field existed and is never proven finalized. Only `true` may be used as merge input or superseded.
- The drainer refuses a marker created before the reference's `lastMasterKeyChangeAt` and marks it conflicted: its payload is ciphertext under the old key and would revert the rekey on the remote. Recovery refuses it too.
- The drainer uploads only when the cache still hashes to the marker's SHA. A mismatch means a sync-down replaced the cache, so it marks a conflict instead of pushing the wrong bytes. A provisional marker whose cache still matches is deferred: neither uploaded nor dropped.
- A conflicted marker is rebased onto the remote head only when the cache matches, `baseRev` equals that head, and the reference already records it. Markers without `baseRev` never rebase.
- A marker may be dropped only by: the drainer after its push returned `.saved` (or the same payload was pushed earlier in the pass); SHA-equality supersession by an app save or a newer AutoFill save, finalized markers only; the AutoFill save dropping its own provisional marker when the save conflicted or threw; `mergePendingUploads` after the merged save uploaded; the user's Discard, after backing up a still-matching cache; removal of the database.
- An app save drops superseded markers only after `applyUploadedBytes`, because a concurrent provisional marker is what triggers that call's backup.
- In-place changes go through `update` (generation compare-and-swap) and `dropIfUnchanged`, under the per-directory `.markers.lock`. `finalize` is deliberately not generation-checked: it writes onto the marker as it is on disk and clears a conflict raised against the provisional hash, so a drain between cache write and finalize cannot strand it.
- If finalize fails, the replacement marker keeps the original `expectedRev` and a nil `baseRev`, so its push conflicts visibly rather than overwrite an app save it cannot rule out.
- Recovery is all-or-nothing: one unreadable or pre-rekey payload makes the lookup `.unavailable`, one unproven marker makes it `.unidentified`. `.unidentified` must never lead to Discard; the change is still on the device.
- A drain request that coalesces onto an in-flight drain forces one more pass, so a mid-drain marker is not left waiting.

### Persisted shapes

- Never persist a rendered sentence. A sync failure is stored as a `CloudSyncIssue` code and localized at display time; new error types conform to `CloudSyncIssueConvertible`. Only `.unknown` carries text.
- `CloudSyncIssue`, `CloudSyncPolicy`, and `PendingUploadQueue.Marker` decode by hand and must keep tolerating older and unknown values (reason in `../AGENTS.md`).

### Credentials and transport

- `CloudTokenStore` holds the Dropbox refresh token and WebDAV/FTP credentials as Keychain items in the group named by `CloudKeychainAccessGroup` in the app `Info.plist`, `AfterFirstUnlockThisDeviceOnly`, with no biometric gate. It is not compiled into the extensions.
- OneDrive tokens live in MSAL's own cache: keychain group `com.microsoft.adalcache` on iOS (second in `KeeForge.entitlements`), `com.microsoft.identity.universalstorage` on macOS (not declared today).
- WebDAV requires `https` unless the user set `allowsUnencryptedHTTP`; FTP always requires `allowsUnencryptedFTP`, because the password travels in the clear. Keep both opt-ins explicit. ATS allows arbitrary loads for user-entered hosts, so this code is the only enforcement.
- WebDAV refuses cross-origin redirects and never forwards credentials.
- FTP command arguments containing CR, LF, or NUL are rejected (checked per Unicode scalar), and passive data connections go to the control host, never an address the server advertises.
- WebDAV file ids and folder paths are decoded, server-relative strings. Never percent-decode them again; encode each segment once when building a URL. OneDrive's `graphURL(path:queryItems:)` takes an already-encoded path for the same reason.
- FTP never writes the database in place or deletes it first: upload to a hidden temporary name, re-check the target's hash, rename over it. A server that refuses to rename onto an existing file gets the database set aside as `.keeforge-backup` and restored on any failure. The stale-upload sweep never touches those backups, since one may be a database's only copy.
- `OAuth2Error.unknown` maps to `.networkUnavailable` on purpose: only the Dropbox refresh token is stored, so an offline call fails at the OAuth stage. Dropbox retries are safe only because both write routes use `strictConflict`.
- OneDrive errors map by Graph error `code` before HTTP status, never by message text. `createFile` always uses an upload session, because the simple `PUT` has no create-only mode.

## Tests

- `CloudDatabaseSaverTests`, `CloudSyncCoordinatorTests`, `CloudSyncModelsTests`, `CloudProviderRegistryTests`, `CloudTokenStoreTests`, `CloudAccountStoreTests`.
- Markers: `PendingUploadQueueTests`, `PendingUploadDrainerTests` (also the rekey cutoff), `PendingUploadRecoveryTests`; the AutoFill side in `CredentialProviderSaveTests`.
- Providers: `WebDAVClientTests`, `WebDAVCloudProviderTests`, `FTPCloudProviderTests`, `FTPListingParserTests`. `DropboxCloudProviderTests` and `OneDriveCloudProviderTests` import the SDKs and are excluded from `KeeForgeMacTests`; run them on iOS.
- Session-side sync and merge: `DatabaseViewModelCloudSyncTests`.

## See also

- `../AGENTS.md`, `../Persistence/AGENTS.md`, `../Security/AGENTS.md`
- `../../ViewModels/AGENTS.md`: merge, rekey, Sync Now, and when markers are merged or refused
- `../../Views/Cloud/AGENTS.md`, `../../../KeeForgeMac/SECURITY.md`, `../../../docs/threat-model.md`
