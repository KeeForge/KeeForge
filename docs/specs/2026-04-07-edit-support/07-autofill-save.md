# Slice 07: AutoFill save / generate + pending-upload queue

> Parent: [`epic.md`](./epic.md) · Depends on: 03, 04, 05, 06

## Goal

Make the AutoFill extension a first-class write surface: when iOS asks the extension to provide a credential for a new account or to save a password the user just typed, KeeForge should be able to (a) present its strong-password generator UI, (b) present an entry creator UI populated from the request, (c) save the new entry into the active database via the same `KDBXWriter` + `LocalDatabaseSaver` path the main app uses, and (d) for cloud-backed databases, queue the upload in App Group storage so the main app drains it on next scene-active. The user's edit is *never* lost — even if the upload fails, even if the extension is killed, the encrypted bytes persist in the cache and the queue marker triggers a retry.

This is the user-visible win the whole epic exists for.

## Background reading: do not corrupt the database

KeePassium's CHANGELOG records *eight* shipped database-corruption regressions in their save path, the most recent in 2.5.171 (Nov 2025): *"Longer saving of AutoFill changes could corrupt database."* Their failure modes are the ones we have to design against: race between the in-memory edit and the on-disk write, KDF-cache going stale after composite-key change, gzip path mishandling, XML escaping regressions on TAB/CR/LF, and the "Save as on sync conflict could overwrite the original" bug from 2.0. Slice 01's round-trip identity tests, slice 02's parse → write → parse fixture suite, slice 04's atomic-replace and background-task wrapping, and *this* slice's "marker durably enqueued before `completeRequest` returns" invariant are what stand between us and shipping the same bugs.

## Scope

**In:**

- `CredentialProviderViewController.prepareInterfaceForPasswordCreation(for:)` — implement the iOS 17+ entry-point. The extension is registered as a credential provider with the password-creation capability via Info.plist. **If the active database has `isReadOnly == true` (slice 04 flag) the handler refuses immediately:** present a brief alert *"This database is read-only. Open KeeForge to enable editing."* and call `extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled))`. No entry creator is presented; no marker is enqueued.
- A new `AutoFillEntryCreatorView` SwiftUI screen presented from the extension. Pre-fills:
  - Title: from `ASCredentialServiceIdentifier` (the calling site, normalized via the existing `CredentialMatcher.searchTerm(for:)`).
  - Username: from `ASPasswordCredentialIdentity.user` if provided by the system.
  - Password: from the strong-password generator (using `PasswordGenerator` from slice 06), with a "regenerate" button and an "edit" button to switch to manual entry.
  - URL: from the calling site identifier.
  - Parent group: the database root (v1 doesn't let users pick a group from the extension to keep memory pressure down).
- A "Save and fill" action that:
  1. Builds an `EntryEdit.createEntry` via `DatabaseDraft` (slice 03).
  2. Encrypts the new database via `KDBXWriter` (slice 02).
  3. Writes to the local cache via `LocalDatabaseSaver.save(...)` (slice 04). For cloud-backed databases, this writes to the cache copy that the extension already uses.
  4. If the source is `.cloud(...)`, writes a pending-upload marker to App Group storage.
  5. Returns the new credential to the calling site via `extensionContext.completeRequest(withSelectedCredential:)`.
- A new `PendingUploadQueue` service:
  - Persisted under `AppGroup/pending-uploads/{databaseId}/{uuid}.json`.
  - Each marker contains exactly: `databaseId`, `encryptedBytesCacheURL` (a stable App-Group-relative path pointing at the cache file the extension just wrote), `openTimeSHA512`, `expectedRev`, `createdAt`, optional `lastSyncError`. **No edit payload.** The encrypted cache file is the source of truth — the marker is just a pointer plus the metadata the drainer needs to push it. This is a deliberate departure from KeePassium's `PendingDatabaseTransaction` design (which carries the typed ops and replays them) because we don't need replay semantics: our cache file already *is* the new state. It also avoids storing plaintext passwords in App Group files.
  - Atomic write via temp+rename. The marker write must complete (and `fsync`) **before** the extension calls `completeRequest`, so a system kill after the system records "AutoFill succeeded" cannot leave the user's edit unpushed and unmarked.
  - On enqueue, post a `CFNotificationCenterPostNotification` on `CFNotificationCenterGetDarwinNotifyCenter` with name `com.keevault.app.pending-upload-enqueued`. The main app subscribes; if it's foregrounded, it drains immediately. (Pattern matches Strongbox's `model/AutoFillDarwinNotification.m`.)
- A main-app drainer:
  - In `KeeForgeApp` / scene phase change to `.active` **and** on receipt of the Darwin notification, scan the queue.
  - For each marker: re-resolve the `DatabaseReference`, read the encrypted bytes from the marker's cache URL, attempt `CloudDatabaseSaver.save(...)` with `expectedRev`. On success, drop the marker. On `.conflict`, leave the marker but record `lastSyncError`, and surface a "X pending uploads have a conflict" indicator on the database row in `DatabaseListView`.
  - Manual "Push pending changes" action in the row context menu when the queue is non-empty.
  - Wrap each drain attempt in `UIApplication.beginBackgroundTask` so it can complete after the user backgrounds the app.
- Lock-during-AutoFill-edit:
  - The Watchdog/inactivity behavior in the extension is the same as the main app's lock policy. If the extension is dismissed/backgrounded, any in-progress draft is dropped (the system kills the extension anyway), but if the user has already tapped "Save and fill", the marker has been written and the edit will be applied.
- Conflict in the extension:
  - **Hardcoded `.cancel`** — if `LocalDatabaseSaver` returns `.conflict` (the cache changed since open), the extension shows "Database changed — open KeeForge to save" and cancels the request. This matches KeePassium's `AutoFillCoordinator+dbSaving.swift:38–48` behavior. The marker is **not** written in this case, since we have no encrypted bytes to push.
- Update the AutoFill cache when the main app saves: after the main app's `LocalDatabaseSaver` or `CloudDatabaseSaver` returns `.saved`, refresh the AutoFill credential identity store so iOS sees the new entry in QuickType.

**Out:**

- Direct upload to Dropbox from the extension (no SwiftyDropbox in extension target; no raw HTTPS Dropbox client). The marker → main app drain path is the v1 mechanism. A future v1.1 slice could add a raw HTTPS upload as a fast path.
- Editing existing entries from AutoFill — v1 only supports *creating*. Edits in the extension are out of scope.
- Picking the parent group from the extension — always uses the database root.
- "Save existing site password I just typed" via `ASCredentialIdentityStore.saveCredential` — the iOS side calls `prepareInterfaceForPasswordCreation` for the equivalent flow in iOS 17+. We support that one entry point, not the legacy `saveCredentialIdentities` API.
- A UI to view, retry, or discard individual pending uploads. v1 surfaces a count and a "Push now" action; everything else is automatic.

## Affected areas

- **New:**
  - `AutoFillExtension/AutoFillEntryCreatorView.swift`.
  - `KeeForge/Services/Cloud/PendingUploadQueue.swift`.
  - `KeeForge/Services/Cloud/PendingUploadDrainer.swift` (main app only).
- **Modified:**
  - `AutoFillExtension/CredentialProviderViewController.swift` — implements `prepareInterfaceForPasswordCreation(for:)`, calls into `AutoFillEntryCreatorView`, calls `LocalDatabaseSaver.save(...)`, calls `PendingUploadQueue.enqueue(...)` for cloud sources, calls `extensionContext.completeRequest(withSelectedCredential:)`.
  - `AutoFillExtension/Info.plist` — declares the password creation capability (`ASCredentialProviderExtensionCapabilities` or the equivalent key for iOS 17+).
  - `KeeForge/App/KeeForgeApp.swift` — drains the pending-upload queue on `.scene` phase becoming `.active`.
  - `KeeForge/Views/DatabaseListView.swift` — adds the pending-upload count badge and "Push pending changes" context-menu action on rows with a non-empty queue.
  - `KeeForge/ViewModels/DatabaseListViewModel.swift` — exposes the pending-upload count per row.
  - `KeeForge/Services/AutoFill/CredentialIdentityStoreManager.swift` — refresh after a save (for both main app and extension paths). It probably already does this on open; verify and add a save-time call if missing.
- **New tests:**
  - `KeeForgeTests/PendingUploadQueueTests.swift`.
  - `KeeForgeTests/PendingUploadDrainerTests.swift`.
  - `KeeForgeTests/CredentialProviderSaveTests.swift` (or whatever the existing extension test class is named).
  - `KeeForgeUITests/AutoFillSaveUITests.swift`.

## KeeForge bits

- **Targets:**
  - `AutoFillEntryCreatorView.swift` — `KeeForgeAutoFill` only.
  - `PendingUploadQueue.swift` — **both** `KeeForge` and `KeeForgeAutoFill` (extension writes; main app reads/drains).
  - `PendingUploadDrainer.swift` — `KeeForge` only.
  - `CredentialProviderViewController.swift` — already `KeeForgeAutoFill`.
  - `KeeForgeApp.swift`, `DatabaseListView.swift`, `DatabaseListViewModel.swift` — already `KeeForge`.
- **project.yml:**
  - Add `KeeForge/Services/Cloud/PendingUploadQueue.swift` to `KeeForgeAutoFill.sources`.
  - The extension already has `LocalDatabaseSaver.swift` (added in slice 04), `KDBXWriter.swift` (slice 02 via Models glob), `DatabaseDraft.swift` (slice 03 via Models glob), `PasswordGenerator.swift` (slice 06).
  - Confirm the extension does **not** depend on SwiftyDropbox or any cloud provider files. Cloud saves happen only via the main app drainer.
  - `Run xcodegen generate`.
- **Accessibility identifiers** (add and preserve):
  - **Preserved:** all existing identifiers in `AutoFillSearchView` and `DatabaseListView`. Slice 07 adds rows but does not rename existing controls.
  - **New (extension):**
    - `autofill-entry-creator.title-field`, `autofill-entry-creator.username-field`, `autofill-entry-creator.password-field`, `autofill-entry-creator.url-field`, `autofill-entry-creator.notes-field`.
    - `autofill-entry-creator.regenerate-password`, `autofill-entry-creator.edit-password-manually`.
    - `autofill-entry-creator.save-and-fill`, `autofill-entry-creator.cancel`.
    - `autofill-entry-creator.database-changed-warning`.
  - **New (main app):**
    - `database-row.pending-uploads-badge`, `database-row.push-pending-action`.

## Testing

- **Unit:** `KeeForgeTests/PendingUploadQueueTests.swift`
  - `test_enqueue_writesMarkerAtomically` — write a marker; force-quit-style failure simulation; assert the marker on disk is either fully present or fully absent.
  - `test_listMarkers_returnsAllForGivenDatabase` — enqueue 3 for db A, 1 for db B; assert the per-DB query returns the right counts.
  - `test_drop_removesMarker_fromDisk`.
  - `test_markConflicted_persistsAcrossRestart` — `markConflicted` then re-instantiate the queue; assert the conflicted flag is still set.
  - `test_markerCodableRoundTrip`.
  - Run: `xcodebuild test -only-testing:KeeForgeTests/PendingUploadQueueTests`.
- **Unit:** `KeeForgeTests/PendingUploadDrainerTests.swift`
  - `test_drain_happyPath_uploadsAndDropsMarker` — stub `CloudDatabaseSaver` returns `.saved`; assert the marker is dropped.
  - `test_drain_conflict_marksConflicted_keepsMarker`.
  - `test_drain_offline_keepsMarkerUnchanged`.
  - `test_drain_writeScopeRequired_surfacesAlertViaList` — assert `DatabaseListViewModel` exposes a one-shot alert state.
  - `test_drain_skipsLocalSourceMarkers` — local-source markers shouldn't even exist (extension only enqueues for cloud sources), but defensively skip them.
- **Unit:** Additions to extension tests
  - `test_prepareInterfaceForPasswordCreation_presentsEntryCreator_withPrefilledTitle`.
  - `test_prepareInterfaceForPasswordCreation_readOnlyDatabase_cancelsWithoutPresenting` — set the active DB's `isReadOnly = true`, drive the entry-point, assert no entry creator was presented and `cancelRequest` was called.
  - `test_saveAndFill_localSource_writesCacheAndCallsCompleteRequest_doesNotEnqueue` — assert no marker was written for `.local` sources.
  - `test_saveAndFill_cloudSource_writesCacheAndEnqueuesMarker_thenCallsCompleteRequest`.
  - `test_saveAndFill_conflict_cancelsRequestWithoutEnqueueing`.
  - `test_drainer_doesNotCheckReadOnlyFlag_drainsExistingMarkers` — pre-seed a marker, flip the DB to read-only, drain, assert the marker is still pushed (markers represent already-authored intent — see `epic.md` cross-slice notes).
- **Integration / UI:** `KeeForgeUITests/AutoFillSaveUITests.swift`
  - Use the existing `UITestDropboxCloudProvider` and `TestFixtures/demo.kdbx` setup.
  - `test_autofill_saveAndFill_localDatabase_addsEntry_visibleInMainApp` — drive the extension via the system AutoFill flow surrogate the existing UI tests use; verify the entry shows up in the main app after exiting AutoFill.
  - `test_autofill_saveAndFill_cloudDatabase_queuesUpload_drainedOnAppActive` — drive AutoFill on a cloud-backed DB; bring main app forward; verify the marker is gone and the stub provider recorded an upload.
  - `test_autofill_saveAndFill_conflict_showsWarning_doesNotAddEntry` — pre-corrupt the cache between unlock and save.
  - Run: `xcodebuild test -only-testing:KeeForgeUITests/AutoFillSaveUITests`.
- **Manual:**
  - Real-device test against a real Dropbox-backed database. Sign up on a website. iOS prompts to save in KeeForge. Save. Open KeeForge. Verify entry exists. Verify Dropbox web UI received the upload.
  - Same flow but with airplane mode enabled at the moment of save: extension reports success (cache updated, marker queued), main app drains successfully when network returns.
  - Same flow but the upload conflicts: trigger by editing the same DB on a second device. Verify the row badge and "Push pending changes" CTA appear.
- **Edge cases that apply:**
  - Extension is killed by the system between `LocalDatabaseSaver.save` returning `.saved` and the marker being enqueued. Outcome: cache has the new bytes; no marker exists. The user's edit is **safe in the cache** but won't be pushed to Dropbox until the user does another save. To prevent this: enqueue the marker *before* calling `completeRequest`. The marker write must be atomic and durable before the extension returns.
  - Active database changes between AutoFill invocations (user picked a different active DB in main app). The extension reads `DatabaseListStore.activeAutoFillDatabase` at session start; subsequent main-app changes don't affect the in-flight extension session.
  - Database is locked when AutoFill starts: the existing unlock prompt fires (`presentUnlockPromptIfNeeded`); the user unlocks; then the entry creator is presented. No change to that flow.
  - Dropbox token expired at drain time: SwiftyDropbox refreshes; if it can't, the marker stays put with `lastSyncError` set, and the row badge surfaces.
  - Multiple markers for the same database with the *same* `expectedRev`: drainer applies them in order. If the first one succeeds (advancing the rev), the second one's `expectedRev` is now stale → conflict. Drainer re-reads metadata, advances `expectedRev` to the latest, and retries the *single* conflicted marker. (This is the only place in v1 where the drainer "auto-recovers" — it's safe because the marker carries the encrypted bytes with the edit baked in, and the only thing that changed is the rev.)
  - The user uninstalls and reinstalls the app: App Group container is wiped along with the queue. Edits in the queue are lost. Document this in CHANGELOG.

## Exit criteria

- [ ] All new unit, integration, and UI tests pass.
- [ ] Manual round-trip on a real device against a real Dropbox account, including the airplane-mode test (extension save, queue, restore network, foreground main app, verify drain).
- [ ] No force unwraps. No SwiftyDropbox imports in any extension-target file.
- [ ] Marker enqueue is `fsync`'d **before** `completeRequest` returns, so a system kill mid-callback doesn't lose the queue marker.
- [ ] Marker contains no plaintext secrets — only the cache URL pointer, hash, and rev metadata.
- [ ] Extension save and main-app drain are wrapped in `UIApplication.beginBackgroundTask` with `defer` cleanup.
- [ ] Darwin notification is posted on enqueue and observed by the main app for immediate drain.
- [ ] All extension save work runs off the main actor.
- [ ] `xcodegen generate` run after the `project.yml` updates; both targets compile cleanly.
- [ ] All affected folder-local `README.md` files are updated to reflect new/changed files, services, and flows introduced by this slice (e.g. `AutoFillExtension/README.md`, `KeeForge/Services/README.md`, `KeeForge/Views/README.md`, `KeeForge/ViewModels/README.md`, `KeeForge/App/README.md`, `KeeForgeTests/README.md`, `KeeForgeUITests/README.md`).
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG entry

`- Added: Save new credentials and generate strong passwords directly from AutoFill, with offline-safe queueing for Dropbox-backed databases.`
