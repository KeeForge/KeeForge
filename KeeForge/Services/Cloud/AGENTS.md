# Cloud Services

**Scope:** the provider abstraction, the cloud-backed open and save pipeline, and the durable pending-upload queue shared by app and AutoFill saves. The shared save sequence and `SaveBaseline` are in `../AGENTS.md`.

## Ownership

- `CloudProvider` is the only boundary the rest of the app talks to; SDK and protocol behavior stays behind it. `CloudProviderRegistry.provider(for:)` resolves one, including the UI-test doubles.
- `CloudSyncModels`: the persisted shapes. Concurrency uses one opaque `rev`; each provider maps its own validator onto it (Dropbox rev, OneDrive cTag/eTag, WebDAV ETag, FTP `sha256:` of the bytes).
- `CloudDatabaseSaver`: local app commits and shared delivery/reconciliation, including online rekey. Exact remote-base bytes drive conflict checks; `remoteHasDiverged` supplies the metadata fallback for legacy markers.
- `CloudSyncCoordinator`: open-time provider policy, confirmed-journal recovery before open, conditional sync-down cache publication, and explicit pending-change discard. Upload confirmation never rewrites a newer local cache.
- `PendingUploadQueue` (compiled into the extensions): marker and immutable payload storage. `PendingUploadDrainer` (app only): ordinary delivery through the shared engine. Draining goes through `DatabaseListViewModel.drainPendingUploadsOnAppActive()`; the second instance `KeeForgeApp` holds only observes the notification. `PendingUploadRecovery`: finds hash-verified pending bytes for an unlocked-session merge.

## Invariants

### Platform scope

- Google Drive and AppAuthCore compile into both apps, with no extension membership. Drive stays unavailable for synchronization and production writes until platform configuration, native Picker E2E, durable caller creation integration and replacement-safety decisions are complete.

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
- Promote recoverable finalized legacy ciphertext by its exact hash before any save replaces cache or rotates backups, under the commit lock and generation CAS. Recovery returns the promoted generation; nil/false finalization remains unproven. Cache-directory sync failure after replacement keeps the durable journal until synchronization succeeds, including confirmed rekeys; it must not report the head synchronized or relinquish that ciphertext early.
- `PendingUploadQueue` retains immutable ciphertext in its existing per-database directory, independently of the mutable cache and the five rotating backups. New markers record intended payload path/hash, exact predecessor hash/operation, inherited remote-base hash/revision, and key epoch. Keep shipped marker field meanings and tri-state finalization unchanged.
- Hold the per-database `.commit.lock` across preparation, coordinated conditional cache replacement, marker finalization and local-head publication. Encrypt before taking this cross-process lock, then recheck the actual cache SHA and persisted epoch. A provisional intent is durable before cache replacement and never notifies the drainer. Recovery finalizes only when both retained payload and committed cache match the intended SHA; legacy intents remain unproven. New interrupted preparations expose hash-verified intended ciphertext for explicit merge or discard, while retaining false finalization and refusing automatic upload.
- Updates and conditional deletion use marker generations under `.markers.lock`. Deleting a marker cleans only its own unreferenced payload. Never drop uncertain attempts on local supersession. A merged replacement must durably record ownership before source markers can be removed; absent a proven replacement, retain all sources.
- Before upload, persist `uploadAttemptID`. After a lost response, compare exact remote bytes to payload and remote base. Payload equality confirms; a base-equal probe permits retry only under actual server CAS with the original validator. Preflight-only uncertainty stays pending because the original request may still complete. An observed different commit-time conditional validator persists `attemptIsFenced` before a merge can transfer ownership; generic authentication/quota/permission errors alone never establish that evidence. `CloudUploadFailure` preserves provider phase evidence: pre-dispatch credential failure or a complete WebDAV 401/403/507/412 rejection can settle this invocation, while a previous unresolved attempt remains fenced. FTP failures before target installation/rename and OneDrive session-creation failures before any chunk likewise prove target content untouched. Transport loss at replacement, timeout at commit, generic mutation 5xx and failed final rename remain uncertain. Disabled replacement never dispatches.
- A remote conflict propagates to the full pending lineage so an unsent descendant cannot suppress the remote refresh needed for a complete merge. Discard first durably backs up the actual hash-verified immutable payload outside rotation; unresolved attempts retain a discard-requested tombstone and ciphertext until delivery or a server fence is proven. Failed backup preserves the marker.
- Adapter retries cannot escape the journal: Dropbox replacement dispatches once; OneDrive never repeats an uncertain final session chunk or an unconditional content PUT. Existing preflight-only race limitations still apply.
- Remote confirmation and published head/epoch do not prove any journal's cache installation survived a restart. Shared local recovery verifies the exact immutable payload, restores only its exact predecessor or a missing pathname by CAS/no-clobber, synchronizes the cache file and its directory, and rechecks bytes/head/epoch before cleanup. A later head permits ancestor cleanup only with a hash-verified immutable descendant and persisted predecessor/absorption lineage; unknown bytes, unrelated heads and epoch changes preserve the journal. Confirmed recovery before offline/manual open never contacts a provider or restamps an already-published rekey.
- Delivery returns `retained` while a confirmed journal still owns ciphertext; it never means synchronized/drained and the drainer must not fallback-drop that snapshot, even when its generation has not changed. Automatic hash supersession and recovery-drop helpers leave confirmed journals to delivery; merge-source cleanup requires a hash-verified durable replacement owner before source deletion.
- A confirmed parent transfers its remote revision/hash ancestry to queued children before deletion. Delivery of an older operation never rewrites cache or marks a newer local head synchronized. Keep confirmation journaled if metadata/ancestry publication fails.
- Old-key markers conflict on explicit epoch mismatch; timestamp cutoff applies to legacy markers. A staged rekey is online-only and carries a persisted epoch and new key-file association, never keys. Its journal fences old-key saves, other drains and sync-down until exact-ciphertext confirmation. Recovery publishes cache and association even without the initiating session, invalidates current/express/legacy quick unlock, and requires typed unlock until a successful new-key persistence conditionally clears that requirement.

### Creation and native file grants

- Create-only operations use durable `.creation` records and immutable ciphertext in the existing upload directory. The ordinary drainer enumerates them before reference lookup, so a created database can recover before it has a list entry. Replacement-marker cleanup must not decode or delete these records.
- Persist the action UUID, literal destination/optional parent ID, original ciphertext/hash and reserved remote ID before content dispatch. A retry reuses that action and ciphertext; an independent deliberate action gets its own UUID. Nil-ID providers cannot retry an unknown attempt merely because a later call is rejected. Real pre-content/terminal no-commit evidence may settle only the current fresh invocation.
- Receipts remain until cache and reference registration are durably/idempotently verified. Completed replay must refuse removed references, a newer head/epoch or different cache bytes; a prepared result must never pair its old key/tree with a newer reference. Restart recovery returns a reference for ordinary unlock, never serialized keys or a new prepared key.
- Durable pause requests do not wait for an active network lease. Automatic recovery preserves current pause state; only an explicit user resume may unpause. Recheck pause/account/cancellation before further content dispatch and registration, and retain accepted/uncertain ciphertext when cancellation cannot undo the remote operation.
- `CloudFileSelecting` grants existing files explicitly. Native account-only OAuth for creating a new file must not require selecting an existing file; native Picker import still requires validated selected IDs. UI results remain bound to the captured provider/account/operation and are rejected after disconnect or disappearance.

### Opening and cache replacement

- Manual policy with a cache performs no provider request. Ordinary pending commits and any rekey journal also keep opening on the local cache. A conflicted immutable pending payload can survive a remote refresh for merge.
- Metadata probes have an open deadline only when a cached fallback exists and the provider does not transfer content for metadata.
- Pin the cache inode before transfer. Publish the download through a coordinated replacement conditional on that inode, under the commit lock, and recheck the rekey fence inside it. Preserve legacy pending bytes in backups before replacing; immutable queue payloads never depend on backup rotation.
- Across awaits use `DatabaseListStore.updateCloudSyncMetadata(for:ifUnchangedFrom:mutate:)`, whose identity includes remote revision/hash, local-head UUID and key epoch. Never claim synchronized while any operation remains pending.

### Persisted shapes

- Never persist a rendered sentence. A sync failure is stored as a `CloudSyncIssue` code and localized at display time; new error types conform to `CloudSyncIssueConvertible`. Only `.unknown` carries text.
- `CloudSyncIssue`, `CloudSyncPolicy`, and `PendingUploadQueue.Marker` decode by hand and must keep tolerating older and unknown values (reason in `../AGENTS.md`).

### Credentials and transport

- Cloud account mutations serialize across providers in the app process. Drive uses only `drive.file`, explicit native Picker grants, PKCE/state/exact callbacks and permission-ID account binding. Provider/account-specific Keychain token archives stay separate from vault keys. Sign-out fences authorization/refresh and attempts a same-row tombstone if deletion fails; simultaneous delete/tombstone failure leaves erasure unproven and restart disconnection dependent on account-defaults persistence.

- `CloudTokenStore` holds the Dropbox refresh token and WebDAV/FTP credentials as Keychain items in the group named by `CloudKeychainAccessGroup` in the app `Info.plist`, `AfterFirstUnlockThisDeviceOnly`, with no biometric gate. It is not compiled into the extensions.
- OneDrive tokens live in MSAL's own cache: keychain group `com.microsoft.adalcache` on iOS (second in `KeeForge.entitlements`), `com.microsoft.identity.universalstorage` on macOS (not declared today).
- WebDAV requires `https` unless the user set `allowsUnencryptedHTTP`; FTP always requires `allowsUnencryptedFTP`, because the password travels in the clear. Keep both opt-ins explicit. ATS allows arbitrary loads for user-entered hosts, so this code is the only enforcement.
- WebDAV refuses cross-origin redirects and never forwards credentials.
- FTP command arguments containing CR, LF, or NUL are rejected (checked per Unicode scalar), and passive data connections go to the control host, never an address the server advertises.
- WebDAV file ids and folder paths are decoded, server-relative strings. Never percent-decode them again; encode each segment once when building a URL. OneDrive's `graphURL(path:queryItems:)` takes an already-encoded path for the same reason.
- FTP never writes the database in place or deletes it first: upload to a hidden temporary name, re-check the target's hash, rename over it. A server that refuses to rename onto an existing file gets the database set aside as `.keeforge-backup` and restored on any failure. The stale-upload sweep never touches those backups, since one may be a database's only copy.
- `OAuth2Error.unknown` maps to `.networkUnavailable` on purpose: only the Dropbox refresh token is stored, so an offline call fails at the OAuth stage. Dropbox replacement dispatches once; the engine owns retry and uncertainty. Create-only retries retain `strictConflict`.
- OneDrive errors map by Graph error `code` before HTTP status, never by message text. `createFile` always uses an upload session, because the simple `PUT` has no create-only mode.

## Tests

- `CloudFileCreationTests` covers durable IDs/bytes, restart, registration faults, independent actions, pause/cancel and actual adapter rejection evidence. Creation compatibility artifacts and conflict-copy lifecycle cases are in `KDBXCompatibilityTests` and `DatabaseViewModelTests`.
- `GoogleDriveAuthorizationTests` and `GoogleDriveCloudProviderTests` cover injected SDK/transport paths on both platforms; `CloudProviderIntegrationTests` pins disabled production availability. Headless tests do not establish credentialed Picker/OAuth or native presentation behavior.

- `CloudDatabaseSaverTests`, `CloudSyncCoordinatorTests`, `CloudSyncModelsTests`, `CloudProviderRegistryTests`, `CloudTokenStoreTests`, `CloudAccountStoreTests`.
- Markers: `PendingUploadQueueTests`, `PendingUploadDrainerTests` (also the rekey cutoff), `PendingUploadRecoveryTests`; the AutoFill side in `CredentialProviderSaveTests`.
- `CloudDatabaseSaverTests` includes Keychain-free real WebDAV/FTP transport rejection recovery, cross-process local-head locking, conditional lineage merge and late uncertain-source confirmation. `OneDriveCloudProviderTests` also exercises queued large-upload session rejection with injected token/transport on iOS; no real account or network is used.
- Providers: `WebDAVClientTests`, `WebDAVCloudProviderTests`, `FTPCloudProviderTests`, `FTPListingParserTests`. `DropboxCloudProviderTests` and `OneDriveCloudProviderTests` import the SDKs and are excluded from `KeeForgeMacTests`; run them on iOS.
- Session-side sync and merge: `DatabaseViewModelCloudSyncTests`.

## See also

- `../AGENTS.md`, `../Persistence/AGENTS.md`, `../Security/AGENTS.md`
- `../../ViewModels/AGENTS.md`: merge, rekey, Sync Now, and when markers are merged or refused
- `../../Views/Cloud/AGENTS.md`, `../../../KeeForgeMac/SECURITY.md`, `../../../docs/threat-model.md`
