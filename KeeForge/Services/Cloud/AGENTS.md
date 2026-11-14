# Cloud Services

**Scope:** the provider abstraction, the cloud-backed open and save pipeline, and the pending-upload queue that carries an AutoFill save to the remote. The shared save sequence and `SaveBaseline` are in `../AGENTS.md`.

## Ownership

- `CloudProvider` is the only boundary the rest of the app talks to; SDK and protocol behavior stays behind it. The WebDAV and FTP protocol clients are the `RemoteFileTransports` package (`../../../Packages/RemoteFileTransports/AGENTS.md`); the two providers own credentials, account ids, conflict handling, and every message. `WebDAVError+CloudProvider.swift` holds the WebDAV messages and must keep `.networkUnavailable` and `.serviceUnavailable` for the failures `isLikelyOffline` treats as offline. `CloudProviderRegistry.provider(for:)` resolves one, including the UI-test doubles.
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

### Durable cloud journal

- App saves publish an immutable encrypted payload and durable intent before replacing the shared cache. A successful local save means cached and queued, not remote delivery. Local/AutoFill replacement truth and revocation remain owned by the local saver.
- `CloudJournalDecision` is the extension-safe pure admission/transition policy. Adapters own filesystem/provider effects. Dispatch requires a durable attempt UUID; only an actual response confirms delivery. Generic errors, remote equality, changed revisions and missing files never settle an uncertain attempt or authorize retransmission.
- Marker generations are CAS protected. Confirmed delivery verifies the exact cache/head/epoch, reconfirms cache and registry durability, transfers predecessor ancestry and durably removes the marker before deleting its payload. Failure retains recovery evidence; confirmed reconciliation never uploads again.
- Cache reads and credential filling remain available when recovery fails. Mutations use strict journal reads; unknown formats and unreadable owners fail closed. A pending journal prevents sync-down from overwriting the shared copy.
- Cloud cache/key publication validates captured reference epoch/date and current ciphertext under cache coordination, immediate try-list, immediate try-commit and local revocation ownership. No provider calls or awaits occur under those locks. Keychain callbacks are keychain-only; legacy reference cleanup runs after release. These synchronous cache checks are a draft performance limitation, not a provider deadline guarantee.
- Stable commit leases live outside the payload directory. Owner code never waits for a list lock while another path holds it and waits for the lease: reverse acquisition must be immediate try and release on contention.
- Shipped marker decoding remains supported. Legacy finalized payloads are snapshotted before overwrite; unidentified provisional markers block mutation. There are no migrations for intermediate unshipped journal schemas.
- Creation records are separate from replacement markers. Persist ciphertext and a paused intent before a single create-only provider call. Persist attempting before dispatch and the returned identity before local registration. Restart/foreground drain never resumes creations automatically; cancellation propagates to the foreground worker, which records a received response but checks cancellation before registration.
- Unknown creation responses retain their nil-ID intent and exportable ciphertext. No remote lookup proves quiescence. Without an identity, mutation on that provider/account is conservatively blocked; reads remain available. Cloud Recovery exports exact SHA-verified payloads and explicitly resumes only prepared/confirmed creations. Reference-only selection retains the unknown request and upload fence; it does not publish a creation receipt. Do not add a forget/resend escape.
- Dropbox writes have no internal retry. Effective write guarantees describe provider limits, including weak WebDAV validators, large OneDrive uploads and FTP preflight-only writes.

### Persisted shapes

- Never persist a rendered sentence. A sync failure is stored as a `CloudSyncIssue` code and localized at display time; new error types conform to `CloudSyncIssueConvertible`. Only `.unknown` carries text.
- `CloudSyncIssue`, `CloudSyncPolicy`, and `PendingUploadQueue.Marker` decode by hand and must keep tolerating older and unknown values (reason in `../AGENTS.md`).

### Credentials and transport

- `CloudTokenStore` holds the Dropbox refresh token and WebDAV/FTP credentials as Keychain items in the group named by `CloudKeychainAccessGroup` in the app `Info.plist`, `AfterFirstUnlockThisDeviceOnly`, with no biometric gate. It is not compiled into the extensions.
- OneDrive tokens live in MSAL's own cache: keychain group `com.microsoft.adalcache` on iOS (second in `KeeForge.entitlements`), `com.microsoft.identity.universalstorage` on macOS (not declared today).
- WebDAV requires `https` unless the user set `allowsUnencryptedHTTP`; FTP always requires `allowsUnencryptedFTP`, because the password travels in the clear. Keep both opt-ins explicit. ATS allows arbitrary loads for user-entered hosts, so this code is the only enforcement.
- WebDAV refuses cross-origin redirects and never forwards credentials.
- FTP command arguments containing CR, LF, or NUL are rejected (checked per Unicode scalar), and passive data connections go to the control host, never an address the server advertises.
- Both rules above, and the response size caps, are enforced inside `RemoteFileTransports`; keep them there.
- WebDAV file ids and folder paths are decoded, server-relative strings. Never percent-decode them again; encode each segment once when building a URL. OneDrive's `graphURL(path:queryItems:)` takes an already-encoded path for the same reason.
- FTP never writes the database in place or deletes it first: upload to a hidden temporary name, re-check the target's hash, rename over it. A server that refuses to rename onto an existing file gets the database set aside as `.keeforge-backup` and restored on any failure. The stale-upload sweep never touches those backups, since one may be a database's only copy.
- `OAuth2Error.unknown` maps to `.networkUnavailable` on purpose: only the Dropbox refresh token is stored, so an offline call fails at the OAuth stage. Only read operations retry; a lost write response remains uncertain even with `strictConflict`.
- OneDrive errors map by Graph error `code` before HTTP status, never by message text. `createFile` always uses an upload session, because the simple `PUT` has no create-only mode.

## Tests

- `CloudDatabaseSaverTests`, `CloudSyncCoordinatorTests`, `CloudSyncModelsTests`, `CloudProviderRegistryTests`, `CloudTokenStoreTests`, `CloudAccountStoreTests`.
- Markers: `PendingUploadQueueTests`, `PendingUploadDrainerTests` (also the rekey cutoff), `PendingUploadRecoveryTests`; the AutoFill side in `CredentialProviderSaveTests`.
- Providers: `WebDAVCloudProviderTests`, `WebDAVErrorMessageTests`, `FTPCloudProviderTests`. The WebDAV and FTP clients, their parsers, and the address rules are tested in `../../../Packages/RemoteFileTransports`. `DropboxCloudProviderTests` and `OneDriveCloudProviderTests` import the SDKs and are excluded from `KeeForgeMacTests`; run them on iOS.
- Session-side sync and merge: `DatabaseViewModelCloudSyncTests`.

## See also

- `../AGENTS.md`, `../Persistence/AGENTS.md`, `../Security/AGENTS.md`
- `../../ViewModels/AGENTS.md`: merge, rekey, Sync Now, and when markers are merged or refused
- `../../Views/Cloud/AGENTS.md`, `../../../KeeForgeMac/SECURITY.md`, `../../../docs/threat-model.md`
