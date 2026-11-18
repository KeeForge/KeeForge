# Cloud Services

**Scope:** the provider abstraction, the cloud-backed open and save pipeline, and the pending-upload queue that carries an AutoFill save to the remote. The shared save sequence and `SaveBaseline` are in `../AGENTS.md`.

## Ownership

- `CloudProvider` is the only boundary the rest of the app talks to; SDK and protocol behavior stays behind it. The WebDAV and FTP protocol clients are the `RemoteFileTransports` package (`../../../Packages/RemoteFileTransports/AGENTS.md`); the two providers own credentials, account ids, conflict handling, and every message. `WebDAVError+CloudProvider.swift` holds the WebDAV messages and must keep `.networkUnavailable` and `.serviceUnavailable` for the failures `isLikelyOffline` treats as offline. `CloudProviderRegistry.provider(for:)` resolves one, including the UI-test doubles.
- `CloudSyncModels`: the persisted shapes. Concurrency uses one opaque `rev`; each provider maps its own validator onto it (Dropbox rev, OneDrive cTag/eTag, WebDAV ETag, FTP `sha256:` of the bytes).
- Pure journal decisions gate delivery and confirmed reconciliation; the saver executes their declared effects against actual storage and provider observations.
- `CloudSyncCoordinator`: when an open contacts the provider, and every replacement of a cloud cache file (`downloadLatestCopy` and confirmed journal recovery).
- `PendingUploadQueue` (compiled into the extensions): marker storage. `PendingUploadDrainer` (app only): the only uploader of markers. Draining goes through `DatabaseListViewModel.drainPendingUploadsOnAppActive()`; the second instance the app owner holds (`KeeForgeApp` on iOS, `AppDelegate` on Mac) only observes the AutoFill notification. `PendingUploadRecovery`: finds a conflicted marker's bytes for a merge.

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

- Missing or weak revision evidence requires a downloaded SHA match against the recorded remote base before dispatch. An uncertain attempt never gains resend permission from metadata or byte equality.
- The app save rebases instead of conflicting only when the remote bytes hash to a state `SaveBaseline` covers, at the divergence gate and after a provider 412, with exactly one retry. The retry's rev is read before the byte check so an edit in between fails `If-Match`. Bytes that differ always conflict.
- The pending-upload push uses the plain gate; it has no baseline.
- The backup is written before the upload, so a local failure cannot leave the remote advanced and the save reported as failed.
- Known residue, not hidden: WebDAV sends `If-Match` only for strong ETags; a OneDrive upload session (over 4 MiB) checks it at session creation, not commit; FTP has no conditional write. Read the site comment before attempting a fix.

### Opening and cache replacement

- `syncIfNeededForOpen` under `CloudSyncPolicy.manual` returns the cache without resolving a provider, unless no cache exists. Explicit requests pass `honorsManualSyncPolicy: false`. The policy only gates checking: saves and drains still upload, and the save's gate catches a remote that moved meanwhile.
- The metadata probe races `openProbeDeadline` only when a cache can stand in; a miss is treated as offline. With no cache it waits out the transport.
- `downloadLatestCopy` pins the existing cache with a hard link before the transfer and before listing markers, then publishes with a coordinated replace conditioned on the pinned inode. A save that lands mid-download then makes the sync fall back to the cache instead of reverting it.
- Do not move the pin after the download (it would pin the newer save and replace it), and do not use a rename-aside (the cache path would be empty during the transfer).
- Sync-downs of one cache file run one at a time in the process (`CacheDownloadLock`); overlapping ones would pin the same inode, and the later publish would refuse the earlier one as a concurrent save. App saves and the AutoFill extension stay outside the lock, so the pin still guards against them. A sync that waited may pin only the cache it saw before waiting or the one the previous sync-down published; anything else is a save from the wait, and it falls back to the cache. Each sync-down returns the bytes it staged, read before its publish, so its data and metadata describe the same download. A waiter whose task is cancelled leaves the queue at once and never downloads.
- Cache replacement backs up the superseded bytes before overwrite when pending work needs protection. Confirmed journal recovery only restores a verified predecessor or missing cache; unrelated divergent bytes remain untouched. A failed backup aborts replacement.
- Cloud state learned across an `await` is written with the captured reference and metadata through `DatabaseListStore.updateCloudSyncMetadata`, not `update(_:)`. Its coordinated CAS preserves unrelated fields, rejects a changed target, factors, head or epoch, and reports a visible but unconfirmed publication separately.

### Durable cloud journal

- App saves publish an immutable encrypted payload and durable intent before replacing the shared cache. A successful local save means cached and queued, not remote delivery. Local/AutoFill replacement truth and revocation remain owned by the local saver.
- `CloudJournalDecision` is the extension-safe pure admission/transition policy, including delivery eligibility and confirmed head/epoch/descendant reconciliation. Adapters supply storage observations and execute declared dispatch/acknowledgement/retirement effects. Adapters own filesystem/provider effects. Dispatch requires a durable attempt UUID; only an actual response confirms delivery. Generic errors, remote equality, changed revisions and missing files never settle an uncertain attempt or authorize retransmission.
- Marker generations are CAS protected. Confirmed delivery verifies the exact cache/head/epoch, reconfirms cache and registry durability, transfers predecessor ancestry and durably removes the marker before deleting its payload. Failure retains recovery evidence; confirmed reconciliation never uploads again.
- Cache reads and credential filling remain available when recovery fails. Mutations use strict journal reads; unknown formats and unreadable owners fail closed. A pending journal prevents sync-down from overwriting the shared copy.
- Cloud cache/key publication validates captured reference epoch/date and current ciphertext under cache coordination, immediate try-list, immediate try-commit and local revocation ownership. No provider calls or awaits occur under those locks. Keychain callbacks are keychain-only; legacy reference cleanup runs after release. App and AutoFill run coordination, full cache hashing and keychain-only publication off the main actor through the shared bounded worker and per-action permit. Cancellation/timeout closes an unclaimed permit; a claimed effect retains authority until completion and cannot be described as no-effect.
- Stable commit leases live outside the payload directory. Owner code never waits for a list lock while another path holds it and waits for the lease: reverse acquisition must be immediate try and release on contention.
- Shipped marker decoding remains supported. Legacy finalized payloads are snapshotted before overwrite; unidentified provisional markers block mutation. There are no migrations for intermediate unshipped journal schemas.
- Metadata can avoid a byte download only through a content-identifying revision declared by the adapter or a matching recorded content digest. WebDAV weak/Last-Modified validators do not identify bytes; FTP’s hash revision does and avoids a second probe transfer. Write guarantees remain separate from this metadata evidence.
- Dropbox and OneDrive replacement content uploads have no application-level retry or uncertain range fallback; shipped create-only behavior is unchanged. OneDrive session setup and reads retain their separate retry policies. URLSession or an intermediary may retry PUT after a lost response, so a later WebDAV or OneDrive rejection cannot prove an earlier write did not commit. FTP preflight mismatch proves no target install, while post-rename failures remain uncertain. Effective write guarantees describe provider limits, including weak WebDAV validators, large OneDrive uploads and FTP preflight-only writes.

### Journal binding

- New cloud markers capture their operation and original database, provider/account/file identity, factor-preference fingerprint and head/epoch/date before any upload. Confirmed rekey reconciliation coordinates cache and registry together, then immediately tries the list, commit and local-owner locks; it rechecks the exact marker and original or already-installed binding before key or cache effects. A failed or unconfirmed publication retains its journal and known ciphertext. Legacy and unknown bindings do not grant automatic delivery authority; authenticated legacy merge and export remain separately verified recovery paths.
- Explicit key-file selection may rebind only ready ordinary markers under the commit lock. Persist authority for both the current and selected preference before publishing the registry, then retire the old authority after confirmed publication. A partial transition blocks delivery until the current registry is durably reconfirmed and its matching authority retained. Uncertain, rekey and legacy records require recovery instead.

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
- `OAuth2Error.unknown` maps to `.networkUnavailable` on purpose: only the Dropbox refresh token is stored, so an offline call fails at the OAuth stage. Replacement uploads do not retry a lost response, even with `strictConflict`; shipped create-only behavior is unchanged.
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

- SDK transport tests use a real client with a unique intercepted host. Replacement upload failure retains its actual journal attempt even when a response was lost or a conflict was returned.

- A conflicted confirmed delivery remains owned by confirmation recovery; discard cannot retire it. Only verified local reconciliation may durably retire its journal and payload.

- Explicit sync/reload can read a remote snapshot while retaining the pending cache and immutable sources. Resolution carries captured source identities in RAM only; it is not installed-cache or key-publication authority. A merge records the exact remote byte baseline and consumes only captured unchanged sources after durable output. Modern missing/corrupt payloads block mutation while valid cached reads remain available.

- An explicit cloud merge authenticates every captured immutable source and the remote snapshot before obtaining a single-invocation RAM context. The context binds the original reference, actual cache head/inode/SHA, source generations and owner epoch; the remote baseline stays separate. It rechecks under cache coordination, immediate try-list, commit lease and local owner before replacement and exact source handoff. Cancellation before claim revokes it; a claimed replacement is not described as no-effect. New sources, changed authority or uncertainty retain ownership. It grants neither Keychain publication nor generic adoption of the current cache.

- Cloud-open authentication distinguishes published metadata from a CAS mismatch. The mismatch's current reference is diagnostic state, never authority for ciphertext read before it; the final key fence still validates the original authenticated tuple. Fresh reads after full settlement remain independent of that obsolete invocation.

- A merge defers only its own enqueue notification until its source handoff has exited coordination/list/commit/owner locks; final action cleanup emits an unconsumed notification if handoff was skipped. The RAM context consumes that callback once. Ordinary saves retain their existing notification timing. Independent preclaim lease contention remains recovery, without waiting in reverse lock order, retries or re-encryption; postclaim failures retain ownership. Stage/errno observers are memory-only diagnostics and never reenter owners or authorize effects.

- Clearing a reconciled marker's expected/base revision also removes permission to use the reference's old content hash as a shortcut. Equality between the reconciled baseline and predecessor/cache SHA does not bind that hash to those bytes; delivery downloads and checks the reconciled SHA. Existing content-identifying revision or bound-hash shortcuts remain available when marker validators have not been cleared.

- A confirmed rekey reconciliation signals only its weak, operation-scoped live ticket after journal retirement. The ticket carries no secret and does not authorize key publication.

- App-owned ordinary cloud saves carry a nonsecret operation ticket through encryption and preparation so later key effects can identify their own installed head.
- Delivery of an already-bound ordinary journal tolerates enabling read-only while retaining its other identity, factor and epoch checks. Rekey authority remains strict; legacy markers with unknown or finalized phase can surface as conflicts, while a false-phase marker stays unchanged, and none authorizes delivery.
