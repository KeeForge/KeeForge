# Slice 05: Cloud save (Dropbox write scope + push)

> Parent: [`epic.md`](./epic.md) · Depends on: 04

## Prerequisite (do this before starting)

Update the Dropbox App Console for the KeeForge app: **Permissions** tab → check `files.content.write` → submit. The app is in Development mode, so this takes effect immediately for the developer's test accounts and does **not** require Dropbox re-review. If at any point the app moves to Production, adding write scope will require re-review (typically a few business days) — sequence the launch around that. Do **not** start coding this slice until the dashboard change is in.

## Goal

Extend the save pipeline so that databases backed by Dropbox can also be written back. The flow mirrors slice 04: encrypt → conflict-check → write → update SHA. The cloud-specific work is (a) requesting the `files.content.write` Dropbox scope and re-authorizing existing users, (b) using Dropbox's optimistic-concurrency `mode: update(rev)` upload mode for a second layer of conflict defense beyond our SHA512 check, and (c) coordinating with the local cache so the cached copy stays in sync with what we just pushed.

**Note on `mode: update(rev)`:** Both KeePassium (`KeePassiumLib/.../DropboxManager.swift:671`) and Strongbox (`StrongBox/DropboxV2StorageProvider.m:263`) use `mode: overwrite` for Dropbox uploads and rely on mtime-epsilon comparisons against `lastSyncRemoteModDate` for conflict detection. Both have shipped recurring sync bugs as a result (FAT32 mtime granularity, `serverModified` jitter, false positives and false negatives). KeeForge using `update(rev)` is a small but real improvement for the "two devices edit at once" case — Dropbox will reject the upload server-side if the rev has advanced. This is layered *on top of* our own SHA512 check, not a replacement: SHA512 catches local-cache divergence, `update(rev)` catches remote divergence between the metadata fetch and the upload.

## Scope

**In:**

- Add an `upload(...)` method to the `CloudProvider` protocol with a signature roughly: `func upload(accountId: String, fileId: String, data: Data, expectedRev: String?, progress:) async throws -> CloudFileMetadata`. The returned metadata reflects the newly-uploaded file (new rev, new modified date, new content hash). `expectedRev` is the optimistic-concurrency token; if `nil`, the upload is unconditional (used only for "first save after re-auth" recovery paths).
- Extend `CloudFileMetadata` with a `rev: String?` field. Dropbox sets this; other providers can leave it `nil`. (We currently only have Dropbox, but the `CloudProvider` protocol must stay generic per `epic.md` cross-slice notes.)
- Implement `DropboxCloudProvider.upload(...)`:
  - Use `SwiftyDropbox`'s `files.upload` with `mode: .update(rev)` when `expectedRev` is non-nil, `mode: .overwrite` only as the explicit recovery path.
  - On `.conflict` or "wrong rev" errors, throw a typed `CloudProviderError.conflict(remoteRev:)` so the caller can route to the conflict UX without sniffing strings.
  - On `.insufficientScope` (or whatever Dropbox v2 returns when a write scope is missing), throw a typed `CloudProviderError.writeScopeRequired` so slice 06 can present a re-auth banner.
- Bump the OAuth scope request in `DropboxCloudProvider.authenticate(...)` to include `files.content.write` (currently `account_info.read`, `files.metadata.read`, `files.content.read` at `DropboxCloudProvider.swift:88–92`).
- Add `DropboxCloudProvider.hasWriteScope(accountId:)` that inspects the stored token's granted scope set. If SwiftyDropbox does not expose granted scopes directly on the refresh token object, fall back to "have we seen `insufficient_scope` recently for this account?" — record that signal in `CloudAccountStore` after the first failed write. Either path is acceptable as long as the answer is correct on the second attempt.
- **Proactive re-auth banner on main app launch.** New `DropboxWriteScopeUpgradeBanner` surface in `DatabaseListView` (one-shot per upgrade): on launch, scan all `DatabaseReference`s; if any `.cloud(.dropbox)` reference's account does not have write scope, present a banner *"KeeForge can now save changes back to Dropbox. Reconnect Dropbox to enable editing — your existing read access will keep working either way."* with `Reconnect Dropbox` and `Not now` actions. Dismissing with `Not now` does **not** disable the banner forever; it represses for 7 days. The banner state lives in `SettingsService` (App-Group key `dropboxWriteScopeBannerLastDismissedAt`).
- **Reads keep working without re-auth.** This slice must not break any read path. Existing refresh tokens authenticate metadata fetches and downloads exactly as before. If the user dismisses the upgrade banner indefinitely, they retain read access to all Dropbox-backed databases. The only thing that breaks is the new save action, which surfaces `writeScopeRequired` and presents the same reconnect prompt at the moment of failure (slice 06 owns the prompt UI).
- A new `CloudDatabaseSaver` enum with the same shape as `LocalDatabaseSaver`:
  - `save(draft:reference:compositeKey:openTimeSHA512:expectedRev:) async throws -> SaveResult`
  - Reads the local cache for the SHA512 conflict check (cache is what we opened from), but also fetches fresh metadata from Dropbox to make sure the rev still matches `expectedRev`. If either check fails → `.conflict`.
  - Encrypts the draft (off-main).
  - Calls `DropboxCloudProvider.upload(...)` with `expectedRev`.
  - On success: writes the same encrypted bytes to the local cache (so the next open doesn't have to re-download), updates the `DatabaseReference.cloudSyncMetadata` with the new rev/contentHash/modifiedAt/lastSyncedAt, and updates the App-Group backup directory just like the local saver.
- `DatabaseViewModel.save()` switches on `databaseReference.source` and calls `LocalDatabaseSaver` for `.local` and `CloudDatabaseSaver` for `.cloud(...)`.
- A small extension on `DatabaseReference` / `CloudSyncMetadata` to track `expectedRev` per session. Captured at open time alongside `openTimeSHA512`.

**Out:**

- The "Save as conflict copy" branch — slice 06 owns the user-facing alert and decides what to call. The saver only reports the conflict.
- A direct upload from the AutoFill extension. The extension uses `LocalDatabaseSaver` to write the cache + queues a marker; the main app's launch-time drainer (slice 07) calls `CloudDatabaseSaver` to push.
- Adding more cloud providers — Dropbox only.
- Background upload while the app is suspended.

## Affected areas

- **New:** `KeeForge/Services/Cloud/CloudDatabaseSaver.swift`.
- **Modified:** `KeeForge/Services/Cloud/CloudProvider.swift` — add `upload(...)` to the protocol; add `CloudProviderError.conflict(remoteRev:)` and `.writeScopeRequired` cases; add `rev: String?` to `CloudFileMetadata`.
- **Modified:** `KeeForge/Services/Cloud/DropboxCloudProvider.swift` — implement `upload(...)`, bump scope request, add the "missing write scope" detection at startup and per-save.
- **Modified:** `KeeForge/Services/Cloud/CloudSyncCoordinator.swift` — add `pushAfterSave(reference:bytes:expectedRev:)` mirror of `syncIfNeededForOpen`. Calls `DropboxCloudProvider.upload`, updates the cache and `DatabaseReference`.
- **Modified:** `KeeForge/Services/Cloud/UITestDropboxCloudProvider.swift` — implement `upload(...)` for UI tests; should record uploads in memory and let tests assert on them.
- **Modified:** `KeeForge/Models/CloudSyncModels.swift` — add `rev` to `CloudFileMetadata`. The existing `requiresDownload(comparedTo:cacheExists:)` already prefers `contentHash`, which is robust; consider also using `rev` when available.
- **Modified:** `KeeForge/ViewModels/DatabaseViewModel.swift` — `save()` routes to `CloudDatabaseSaver` for cloud sources; captures `expectedRev` at open.
- **New tests:** `KeeForgeTests/CloudDatabaseSaverTests.swift`, additions to `KeeForgeTests/DropboxCloudProviderTests.swift` (or whatever the existing test class is named — see `KeeForge/Services/README.md`).

## KeeForge bits

- **Targets:** `CloudDatabaseSaver.swift`, `CloudProvider.swift`, `DropboxCloudProvider.swift`, `CloudSyncCoordinator.swift` are all main-app-only — they live under `KeeForge/Services` glob, which the extension does not include. Do **not** add any of these to `KeeForgeAutoFill.sources`.
- **project.yml:**
  - No changes (cloud files are already main-app only).
  - `Run xcodegen generate` not needed.
- **Accessibility identifiers:** N/A — slice has no view layer.

## Testing

- **Unit:** `KeeForgeTests/CloudDatabaseSaverTests.swift`
  - `test_save_happyPath_uploadsBytes_updatesCacheAndMetadata` — use a `UITestDropboxCloudProvider` stub. Apply an edit, save, assert: stub recorded an upload with `mode: .update(rev: <expected>)`, local cache file at `DatabaseListStore.cacheLocation(for:)` equals the encrypted bytes, `cloudSyncMetadata.remoteContentHash` and `lastSyncedAt` were updated.
  - `test_save_revChangedRemotely_returnsConflict_doesNotWriteCache` — stub provider returns "conflict" for the upload. Saver returns `.conflict`. Local cache is unchanged. Backup not created.
  - `test_save_localCacheChangedSinceOpen_returnsConflict_beforeUploadAttempted` — stub the local cache so its SHA512 differs from `openTimeSHA512`; assert the saver returns `.conflict` and never called the stub provider's upload.
  - `test_save_writeScopeMissing_throwsWriteScopeRequired` — stub provider throws `writeScopeRequired`; saver propagates it; `DatabaseViewModel.save()` exposes it as a typed error for slice 06.
  - `test_save_networkFailure_doesNotCorruptCache` — stub provider throws a network error mid-upload; assert local cache is unchanged.
  - `test_save_savesBackup_likeLocalSaver` — same backup directory + 5-file pruning behavior as slice 04.
  - Run: `xcodebuild test -only-testing:KeeForgeTests/CloudDatabaseSaverTests`.
- **Additions to existing Dropbox provider tests:**
  - `test_authenticate_requestsWriteScope` — assert the `ScopeRequest` constructed in `DropboxCloudProvider.authenticate` includes `files.content.write`.
  - `test_isMissingWriteScope_detection` — given a stored token whose granted scopes lack write, the provider reports the account as needing re-auth.
- **Integration / UI:** N/A in this slice — slice 06 owns the re-auth banner UI.
- **Manual:** Sign in to a real Dropbox account on a debug build, edit an entry, save. Verify in the Dropbox web UI that the file was updated and the rev advanced. Then sign out and re-sign-in with an old account that pre-dates this change; verify the re-auth prompt fires.
- **Edge cases that apply:**
  - User opens DB at rev A, another device pushes rev B, user saves → conflict.
  - User opens DB at rev A, network drops, user saves → cache is unchanged, error surfaced.
  - User opens DB at rev A, hits save twice rapidly → second save sees that the first save advanced the in-session rev to B and uses B as `expectedRev`.
  - User opens a `.cloud` DB while offline (cached fallback path), tries to save → save attempts the conflict check via remote metadata fetch, fails with offline, surfaces "no network — try again later". Cache is unchanged.
  - Token expired mid-save — SwiftyDropbox should refresh; if refresh fails, surface re-auth.

## Exit criteria

- [ ] Dropbox App Console permission for `files.content.write` is enabled before slice work begins (see Prerequisite).
- [ ] All cloud saver tests pass.
- [ ] Manual round-trip against real Dropbox: edit → save → verify on web UI → reopen on KeeForge → entries are correct.
- [ ] **Reads keep working without re-auth.** Manual verification: install the new build over a build that only has read scope; do *not* tap the upgrade banner; open a Dropbox-backed database; assert the open succeeds and AutoFill from QuickType works. Only the save path should surface the re-auth prompt.
- [ ] **Proactive upgrade banner** appears on first launch after upgrade for any user with a `.cloud(.dropbox)` database whose token lacks write scope; dismissing it suppresses for 7 days; tapping `Reconnect Dropbox` runs `authenticate(...)` with the new scope set and the database becomes writable.
- [ ] No force unwraps.
- [ ] All upload work runs off the main actor.
- [ ] All affected folder-local `README.md` files are updated to reflect new/changed files, services, and flows introduced by this slice (e.g. `KeeForge/Services/README.md`, `KeeForge/ViewModels/README.md`, `KeeForgeTests/README.md`).
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG entry

`- Internal: Dropbox-backed databases can now be saved back to Dropbox with optimistic-concurrency conflict detection.`
