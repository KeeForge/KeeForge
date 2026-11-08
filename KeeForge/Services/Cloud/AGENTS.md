# Cloud Services

**Scope:** the provider abstraction, the cloud-backed open and save pipeline, and the durable pending-upload queue shared by app and AutoFill saves. The shared save sequence and `SaveBaseline` are in `../AGENTS.md`.

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

- The active modularization contract is [../../../docs/cloud-sync-contract.md](../../../docs/cloud-sync-contract.md). `writeGuarantee` distinguishes commit-time server exclusion from preflight checks; an opaque revision alone establishes no guarantee. Disabled replacement must be rejected by both the shared engine and adapter.
- A provider requiring a generated creation identity implements `prepareFileCreationID` and the `creationID` overload. The caller must persist that identity with the intended ciphertext before dispatch and reuse it after uncertainty; the legacy overload must refuse if it cannot preserve that guarantee.
- `createFile` is create-only on every provider and must never replace an existing file; database creation and conflict copies depend on it. It must not filter by extension either: a conflict copy keeps the database's own extension.
- `listFiles` filters through `CloudFile.isListed`. Dropbox's server-side search filter must be dropped when `includesAllFiles` is set. FTP never lists its own scratch files (`isScratchName`): one opened as a database could later be swept.
- `download` returns the metadata of the bytes it wrote, or nil when the transport cannot say. Record that in preference to the earlier `getMetadata` reading, which goes stale if someone writes mid-transfer.
- An upload response may omit rev or hash. Never overwrite a recorded value with nil, or every later save falls into the weaker nil-rev gate.
- A provider whose `getMetadata` must transfer the file sets `metadataProbeTransfersContent` (FTP), which exempts it from the open-probe deadline.

### Local commits and delivery

- Ordinary app and AutoFill saves commit locally before networking. `SaveResult.saved` proves encrypted local durability, not upload. `CloudDatabaseSaver` notifies the queue; `PendingUploadDrainer` owns ordinary delivery.
- `PendingUploadQueue` retains immutable ciphertext in its existing per-database directory, independently of the mutable cache and the five rotating backups. New markers record intended payload path/hash, exact predecessor hash/operation, inherited remote-base hash/revision, and key epoch. Keep shipped marker field meanings and tri-state finalization unchanged.
- Hold the per-database `.commit.lock` across preparation, coordinated conditional cache replacement, marker finalization and local-head publication. Encrypt before taking this cross-process lock, then recheck the actual cache SHA and persisted epoch. A provisional intent is durable before cache replacement and never notifies the drainer. Recovery finalizes only when both retained payload and committed cache match the intended SHA; legacy or uncommitted intents remain unproven.
- Updates and conditional deletion use marker generations under `.markers.lock`. Deleting a marker cleans only its own unreferenced payload. Never drop uncertain attempts on local supersession. A merged replacement must durably record ownership before source markers can be removed; absent a proven replacement, retain all sources.
- Before upload, persist `uploadAttemptID`. After a lost response, compare exact remote bytes to payload and remote base. Payload equality confirms; a base-equal probe permits retry only under actual server CAS with the original validator. Preflight-only uncertainty stays pending because the original request may still complete. Disabled replacement never dispatches.
- A confirmed parent transfers its remote revision/hash ancestry to queued children before deletion. Delivery of an older operation never rewrites cache or marks a newer local head synchronized. Keep confirmation journaled if metadata/ancestry publication fails.
- Old-key markers conflict on explicit epoch mismatch; timestamp cutoff applies to legacy markers. A staged rekey is online-only and carries a persisted epoch and new key-file association, never keys. Its journal fences old-key saves, other drains and sync-down until exact-ciphertext confirmation. Recovery publishes cache and association even without the initiating session, invalidates current/express/legacy quick unlock, and requires typed unlock until a successful new-key persistence conditionally clears that requirement.

### Opening and cache replacement

- Manual policy with a cache performs no provider request. Ordinary pending commits and any rekey journal also keep opening on the local cache. A conflicted immutable pending payload can survive a remote refresh for merge.
- Metadata probes have an open deadline only when a cached fallback exists and the provider does not transfer content for metadata.
- Pin the cache inode before transfer. Publish the download through a coordinated replacement conditional on that inode, under the commit lock, and recheck the rekey fence inside it. Preserve legacy pending bytes in backups before replacing; immutable queue payloads never depend on backup rotation.
- Across awaits use `DatabaseListStore.updateCloudSyncMetadata(for:ifUnchangedFrom:mutate:)`, whose identity includes remote revision/hash, local-head UUID and key epoch. Never claim synchronized while any operation remains pending.

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
