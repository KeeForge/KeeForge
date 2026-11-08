# Active cloud synchronization contract

Status: implementation contract for the cloud modularization worktree. Baseline: `dc49954705ef9ccfd7be7a962e0d8d350e44e3c7`. This document is maintained during implementation; historical specs are unchanged.

## Boundary and product semantics

The shared engine owns local durability, pending changes, remote reconciliation, backups, retry policy, conflict recovery and status. Providers own authentication, file authorization/selection, transport, metadata and truthful service guarantees. They receive encrypted KDBX bytes only, never vault keys, passwords, XML or merge logic. No backend, plugins or second upload queue.

A successful ordinary app save means an encrypted local commit and a durable pending intent, regardless of connectivity. `SaveResult.saved` means durable locally; it does not mean synchronized. Only confirmed upload or byte-equality reconciliation may advance remote synchronization status. Reading and local saving remain available offline. KDBX 3.1 and hardware-key read-only restrictions remain.

## Pending change and remote base

Extend `PendingUploadQueue`, keeping its directory, marker decoder and existing field semantics. A change consists of database identity, operation identity (stored marker UUID), exact payload SHA-512, immutable encrypted payload location relative to App Group, local predecessor SHA-512, remote base (opaque revision plus exact base-byte SHA-512 when known), creation time/key epoch and delivery state. Persisted additions default conservatively for shipped markers; `isPayloadFinalized` remains tri-state, and legacy/unproven markers are never treated as known payloads.

For new app saves, retain the pending ciphertext independently of the mutable cache and rotating backups, in the existing queue's per-database storage. This is payload storage for the same queue, not a second queue. Marker deletion and payload cleanup must be conditional on the same generation; never remove a payload still referenced by another operation. Legacy AutoFill markers continue to resolve their cache/backup by exact hash.

Persisted engine additions are optional and decode conservatively: a local-head operation UUID on CloudSyncMetadata; predecessor operation UUID, remote-base SHA-512, intended payload SHA-512/location and upload-attempt state on markers. Legacy absent local-head is unknown, not a matching UUID. Confirmation metadata updates must compare observed local-head identity as well as remote rev/hash, and never set a newer pending operation synchronized. The engine worker owns exact Swift spelling and storage encoding of these fields; their semantics are fixed here.

The remote base is what the local change actually descends from. A second local edit derives from its pending predecessor and inherits that predecessor's remote base, rather than interpreting its local ciphertext as a new remote head. Supersede an operation only after a durable replacement proven to contain it, with no uncertain in-flight upload unaccounted for. A revision is an observation, not an exclusion guarantee.

## Local commit and crash recovery

Keep `SaveBaseline` as the local overwrite gate and recheck inside the coordinated replacement. Encrypt/verify off the main thread. Before replacing cache: preserve the actual old bytes as a backup, durably write intended ciphertext, and durably publish a provisional intent without waking the drainer. Then atomically/durably replace cache conditioned on the predecessor hash, finalize the marker, and notify. Failed replacement never becomes an eligible upload. A crash after replacement but before finalization must recover by comparing the cache to the recorded intended payload; never guess from a provisional base hash. A crash before replacement keeps the prior committed state; retain unidentified payloads for recovery, not automatic upload.

Cache refresh, download, drain completion and backup pruning must never destroy the sole pending ciphertext. A completed older upload must not replace a newer local cache or roll back its metadata. Use coordinated inode/hash checks and DatabaseListStore's conditional metadata updates across awaits. App/AutoFill processes can overlap; process-local serialization alone is insufficient.

## Delivery and uncertainty

Logical states: prepared (not eligible), pending (local commit), uploading/uncertain (attempt durably recorded before network mutation), conflicted, confirmed. Existing generation compare-and-swap and finalize rules stay authoritative. Persist attempt uncertainty before sending so a crash after server acceptance is distinguishable from an unsent operation.

Providers can preserve explicit upload evidence with CloudUploadFailure: notDispatched, rejected, or uncertain. Only a phase/response proving no commit settles a fresh attempt; rejection of a later invocation never settles an earlier unresolved one. WebDAV preserves pre-dispatch credential failures and complete 401/403/507/412 rejection responses. FTP preserves pre-installation failures, switching conservatively to uncertainty before target/backup rename; OneDrive session-creation failures precede all content chunks. Opaque errors, lost responses and ambiguous server failures remain uncertain.

On any upload failure after possible dispatch, retain ciphertext and reconcile before another mutation: obtain remote bytes/metadata; exact payload equality confirms delivery, exact remote-base equality permits a retry only with server commit CAS/idempotency or proven quiescence of the original attempt, anything else is conflict. A failed/unavailable probe leaves uncertainty pending. A base-equal probe cannot fence a still-executing request; for preflight-only transports preserve uncertainty until quiescence is established rather than resending blindly. Never clear uncertainty because of a timeout, cancellation, connectivity error or missing response. Do not retry creation with a new identity. Authentication revocation, permissions and quota keep the local commit pending with an actionable issue; reconnect/retry are engine policy. No busy retry loop. Discard requests keep unresolved attempt fences and immutable bytes; a retained-change message must remain visible. Back up the actual hash-verified payload into non-prunable storage before removing a conflicted marker. A changed server-conditional validator can establish that its old attempt is fenced; preflight transports cannot infer this from a byte probe. Propagate conflicts across pending descendants so an explicit refresh and session merge can include the remote head. Uncommitted new preparations require explicit recovery/discard, never blind upload.

## Provider write guarantee

The app-only `CloudProvider` seam gains `writeGuarantee(expectedRev:byteCount:) -> CloudWriteGuarantee`, with `serverConditional`, `preflightOnly`, and `disabled`. Default is conservative `preflightOnly`. `serverConditional` means the service enforces the supplied validator at actual content replacement, not only before transfer/session creation. Provider metadata `rev` remains opaque and is never promoted to a stronger guarantee.

Dropbox with a known rev is conditional. OneDrive simple upload with a valid If-Match can be conditional; large upload sessions are preflight-only unless commit exclusion is proven. WebDAV strong ETag is conditional; weak/missing ETag and FTP are preflight-only. Preserve existing provider/platform behavior and disclose these existing limitations; do not silently expand their guarantees or disable installed users. Google Drive replacement is disabled because no documented content CAS has been established. Drive `version`/`headRevisionId` must not be sent as invented If-Match validators. A common engine guard and the Drive adapter both reject disabled replacement.

## Rekey, merge and session lifetime

Keep rekey/encryption changes gated on no pending old-key changes. Cloud rekey requires an online preflight and rejects offline before mutation. Extend the session's cloud save context with a durable rekey epoch and new key-file bookmark/filename association (never key-file bytes, vault keys or passwords). Verify the new-key ciphertext, then durably stage it and its recovery context before any upload; retain the old cache until remote outcome is known. Record uncertainty before dispatch and reconcile the exact staged bytes after a lost response, crash or restart. Base equality cannot fence a delayed original request. Persisted cache, reference/key-file association and epoch must converge from the journal even if the initiating session locked or disappeared; failed quick-unlock key persistence must invalidate the stale old-key item and allow typed unlock with the correct association. New-key journal records must not be rejected by their own cutoff. Concurrent old-key AutoFill bytes remain retained recoverable conflicts. Do not preserve the old online path's response-lost gap.

Merge only within a valid unlocked session, off main for crypto/parsing. Session lock-cycle checks continue to prevent stale completions restoring secrets.

## Google Drive adapter

Use `drive.file` only and Google's explicit native browser Picker grant for existing files. File identity is `fileId`, not name/path. REST transport plus maintained AppAuth-iOS (iOS/macOS) with S256 PKCE and unpredictable state; verify SDK types before coding. Bind callbacks exactly to a single outstanding authorization and bind account to `about.user.permissionId`, rejecting reconnect account mismatch. Credentials use provider/account-specific Keychain items separate from vault keys; no embedded client secret or sensitive logs. Client IDs/callbacks must be valid for each platform, otherwise unavailable.

The fixed provider seam adds prepareFileCreationID(accountId:) returning an optional service-generated ID, plus a createFile overload accepting creationID. Legacy providers default to nil preparation and their existing create-only route; Drive requires a nonnil pre-generated ID and its legacy overload refuses creation. The common caller owns durable operation/payload identity and the prepared ID before dispatch; no provider-owned retry queue. Creation/conflict copies use a pre-generated ID persisted with payload identity before the first create; retries reuse it. A 409 requires exact-ID content reconciliation, never overwrite-by-name or allocating a new ID. Duplicate names are valid Drive semantics. No real account tests or OAuth publication without explicit authorization. Feature stays unavailable for real use without supplied configuration, proven native Picker interoperability and a product decision on replacement safety. Read/create-only is a possible future product mode, not silently substituted for full synchronization.

## Ownership for child worktrees

Every editor starts from the exact signed contract commit of this integration branch. No child may edit another owner's files without coordinator reassignment. No pushes, PRs, issues, app installs or app launches.

- Engine worker: existing shared cloud save/sync/queue/recovery/models and existing provider capability implementations; AutoFillSaveCoordinator; LocalDatabaseSaver durability primitives if needed; DatabaseViewModel/List save integration; matching existing tests and new engine-specific tests. Own folder invariants for these files. Excludes GoogleDrive-prefixed files, CloudProvider.swift/CloudWriteGuarantee.swift, registry, UI, build config, catalogs, changelog and threat model.
- Drive worker: new `GoogleDrive*` source/test files only. Implement OAuth/Picker, REST transport, error mapping, metadata, downloads, ID-based safe creation and disabled replacement against the fixed provider seam. Supply exact integration edits required as a report, not edits to shared config/registry/UI/catalogs. No build while engine testing unless granted an isolated DerivedData schedule.
- Independent reviewer: read-only counterexample audit of contract, engine and provider implementation; no source/test edits and no concurrent Xcode builds. Report severity, trigger, precise lines and missing evidence. Final integrated diff gets a fresh independent review.
- Coordinator: provider seam/guarantee definition, registry/provider-kind/UI/config/entitlements/project generation, catalogs, changelog, threat model and cross-owner integration. Integrate signed commits, resolve conflicts and schedule validation.

Temporary evidence, specs for workers and DerivedData go only under the main checkout's gitignored scratch directory. Use focused `-only-testing:` slices, no full UI suite. Engine verification covers actual storage/restart, coordinated concurrent writers, crash steps, lost upload response, revoked token/quota/permissions, rekey and AutoFill; update and run relevant KDBX compatibility tests. Regress existing providers on their existing platforms; localization normalization/tests if catalogs change. Headless tests do not establish iPhone/iPad/Mac UI or credentialed OAuth E2E.

## Primary evidence and external gates

Reviewed 2026-11-08: [Drive authorization](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [native Picker](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker), [files.update](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update), [uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads), [revisions](https://developers.google.com/workspace/drive/api/guides/manage-revisions), [pre-generated IDs](https://developers.google.com/workspace/drive/api/guides/create-file), [AppAuth](https://github.com/openid/AppAuth-iOS). Absence of documented CAS is not proof of server behavior; successful racing experiments would not establish a guarantee either.

External gates: platform OAuth client IDs/project/callback configuration; authorized test account/file; native Picker/SDK validation; product decision if Drive cannot meet replacement safety. Do not report Google Drive ready without E2E evidence.

## Configuration handoff

The adapter uses the exact AppAuth 3.0.0 `AppAuthCore` product in both apps; hosted tests import through their app-host dependency so the app alone owns the static Objective-C symbols; extensions link neither OAuth nor transport code. iOS Info.plist reads `GOOGLE_DRIVE_IOS_CLIENT_ID` and `GOOGLE_DRIVE_IOS_REDIRECT_URI`; macOS reads the corresponding `GOOGLE_DRIVE_MAC_*` settings. No values or callback schemes are supplied. A configured native client requires its registered reversed-client-ID scheme and `/oauthredirect` URI. Do not add a placeholder scheme to shipping bundles. The adapter's `selectFiles(from:expectedAccountID:)` is the explicit authorization seam; the generic folder browser is not a grant for existing Drive files. No production menu enables it until the external gates above are met.

## Open implementation and acceptance work

These items are pending and are not satisfied by the adapter implementation or passing headless tests. App/device validation is deferred to the later test stage; do not install or launch the app to close this checklist during implementation.

Implementation/configuration/decisions:

- [ ] Supply the Google Cloud project and real OAuth client IDs/registered callbacks per platform, then wire the declared configuration without embedded secrets or placeholder schemes.
- [ ] Connect existing-file import and account reconnect UI to the native Picker `selectFiles(from:expectedAccountID:)` flow, preserving the selected account and explicit file grants. The adapter method exists; the production UI is not wired or enabled.
- [ ] Integrate durable creation/conflict-copy intents in the common caller: retain operation identity, encrypted bytes/hash and generated file ID before dispatch, reuse them after restart, and reconcile lost responses by that exact ID. The adapter API exists, but production callers do not yet persist/use this creation context. Its current create API targets My Drive root; folder destinations require an explicit parent-ID seam rather than treating a name/path as identity.
- [ ] Decide the acceptable Drive concurrent-write product behavior. Existing-file replacement is disabled; observation/version reads do not establish commit exclusion. Any alternative behavior requires an explicit decision and implementation before enabling writes.
- [ ] Enable production provider availability/creation only after the preceding implementation, safety decision and acceptance evidence are complete. Do not treat enabling a flag as completing the work.

Later test-stage acceptance (all pending):

- [ ] Run iOS unit/regression tests once the simulator-service infrastructure is usable; include iOS-only OneDrive/Dropbox and the large-upload rejection/retry case.
- [ ] Exercise native OAuth/Picker on iPhone, iPad and Mac with an authorized test account/file: scope/grant, callbacks/PKCE, cancel/replay, account mismatch, reconnect/revocation, refreshed-token persistence and sign-out.
- [ ] Exercise the signed app plus AutoFill using real Keychain entitlements: offline save/restart, overlapping app/extension edits, rekey/key-file association, lock/cancel and recovery after interrupted publication. Resolve the currently skipped Keychain tests.
- [ ] Validate provider E2E and two writers: offline edits followed by foreign remote changes, merge/refresh, quota/permission failures, lost response, delayed upload and retained-discard behavior. Record each provider's actual concurrency limits rather than claiming server exclusion from a successful race test.
- [ ] Verify native UI, pending/conflict/recovery copy, accessibility and translations on iPhone/iPad/Mac; headless view-model tests do not close this item.
- [ ] Exercise crash/fsync-failure boundaries and power-loss behavior beyond the current injected-step/filesystem regressions; record any limits that cannot be established.

The shared engine has no remaining known blocking source finding after independent review. Google Drive remains an incomplete, gated product integration until the open items above are resolved.

## Validation handoff — 2026-11-08

Source reviewed independently through `18b0ce1`; no remaining actionable correctness/security finding was reported. Build graph simplified and verified at `deb8065`; XcodeGen regeneration is stable. These receipts overlap and must not be summed as unique coverage.

| Check | Result | Scope or limit |
| --- | --- | --- |
| Final integrated Mac focused run | 81 cases: 77 passed, 4 Keychain skips, 0 failed | Google Drive auth/transport, shared engine, rekey guards, discard presentation, LocalizationTests and URL schemes; ad-hoc host with empty entitlements |
| AppAuth imports through host only | 19 passed, no skips | SDK-enabled authorization suite after removing redundant direct test-package linkage |
| Engine broad Mac regression | 262 cases: 244 passed, 17 Keychain skips, one obsolete unsafe-discard assertion | The assertion was corrected and explicitly passed in the final affected eight-case run; no blanket all-green claim for the original run |
| Engine final affected regression | 8 passed, no skips | Real fake-FTP rejection recovery, earlier uncertainty fence, late source/merge-owner delivery, unreadable-payload retention and WebDAV write behavior |
| Final integrated iOS build-for-testing | Exit 0 | App, AutoFill and selected test targets compile with final engine, Drive/AppAuth, large OneDrive test and catalog; no runtime claim |
| iOS runtime | Not executed | Two existing simulators failed DTServiceHubClient/service-hub startup before the test host; both attempts stopped and devices returned to shutdown |

KDBX compatibility coverage includes AES/Twofish offline ciphertext snapshot preservation. Existing-provider tests retain their platform exclusions. No real OAuth, provider account, release or interactive app launch was performed. Builds and hosted test runners used scratch/simulator test locations; production app installations were not changed. Native iPhone/iPad/Mac presentation, signed app/extension contention, hardware/Keychain recovery and true power-loss/fsync fault behavior remain unverified. Drive stays unavailable: platform client IDs, authorized native Picker/OAuth E2E, durable creation caller integration and a replacement-safety product decision are still required.

Reproducible receipts are in the main checkout's disposable `scratch/cloud-modularization/`: `final-integrated-mac.xcresult`, `final-host-import-mac.xcresult`, `final-integrated-ios-build.log`, and `engine-validation.txt`. These are development evidence, not release artifacts.

## Completion slice — fixed integration contract

This slice completes implementation rather than deferring source work to acceptance. Real app/device runs remain deferred by user instruction. Build-for-testing, source checks and authored focused regressions are allowed; never execute a hosted test app or native OAuth during this slice.

- `CloudFileSelecting` is the app-only explicit native-grant capability. Import/reconnect captures the expected account and request generation, calls its Picker method, rejects mismatched/late results, and returns user-selected files without treating a custom listing as authorization. Google account connection for creation uses a separate scope-limited OAuth flow without forcing file selection. Picker validation remains mandatory for existing-file grants; callback/state/PKCE/account/signout fences apply to both flows.
- `CloudFileCreationTarget` carries the provider's literal name/path plus an optional opaque parent file ID. Existing adapters retain their path behavior; Drive uses a literal name and explicit parent ID, or My Drive root when none is selected. Never split or infer a Drive path/name as identity.
- Durable creation is part of the existing pending-upload infrastructure, not a provider queue. Pure Codable creation intents and encrypted payloads reside in the existing per-operation queue storage, separately identifiable from ordinary replacement markers. One common app delivery owner resumes them. Persist operation UUID, provider/account, destination, exact ciphertext/hash and generated remote ID before first content mutation. Persist enough non-secret registration context to recover a created database/reference after restart without re-encryption or keys. A conflict-copy receipt also retains stable identity across caller retries. Pending/uncertain attempts survive cancellation and process restart; repeat only with the same service ID and bytes, reconcile exact-ID 409, never allocate a new ID to retry an unresolved operation. Keep receipts through durable cache/reference registration so a local completion failure cannot duplicate the remote object.
- New-database creation uses its prepared database UUID as operation identity. Conflict-copy identity remains stable for the same user action/content across retry/restart, and no pending ciphertext or receipt disappears before safe ownership transfer. Existing providers without generated IDs keep their existing create-only path; do not add blind retry to weak transports.
- Provider availability remains governed by real configuration and the unresolved Drive replacement guarantee. Complete the UI/creation implementation behind the gate; do not enable unsafe overwrite or claim E2E readiness. Complete platform callback wiring only from actual valid supplied configuration, never invented IDs or schemes.

Ownership for child worktrees from the signed commit of this completion contract:

- Creation worker: new common creation coordinator/intent persistence, `PendingUploadQueue` creation-record support, `PendingUploadDrainer` creation resumption, `DatabaseCreationService`, the conflict-copy method in `DatabaseViewModel`, `GoogleDriveCloudProvider` account-only/typed-target integration, and matching creation/provider tests. No other session methods, UI, OAuth implementation/configuration, build files or catalogs. Keep extension-shared storage pure and in existing allow-lists.
- Picker worker: `GoogleDriveAuthorization`, `GoogleDriveConfiguration`, their focused authorization tests; `CloudFileBrowserSession`, `CloudFileBrowserView`, `DatabaseCreationViewModel`, `DatabaseCreationView`, and matching browser/creation-view-model tests. No creation storage/service, provider implementation, shared protocol/models, build files or catalogs. Provide exact new English keys to coordinator for full translations.
- Coordinator: fixed common seams, build/plist/registry/platform gates, catalogs, invariants/threat model/checklist integration and conflict resolution; no overlapping worker file edits while active. Independent reviewer remains read-only on signed stable revisions. Each writer commits with DCO and supplies source/compile evidence plus pending runtime selectors, with all artifacts in the main checkout scratch.
