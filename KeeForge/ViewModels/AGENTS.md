# ViewModels

**Scope:** `@MainActor @Observable` app state and UI-independent workflow owners. Use Foundation/Observation, never SwiftUI (enforced by `ci_scripts/validate_architecture.py`). Heavy work goes to services or detached tasks; only the result is published here.

## Ownership

Name the owner before changing a workflow. Views render, collect input, and forward lifecycle events; they never repeat the policy owned below. Add a coordinator only for a distinct responsibility, composing `DatabaseViewModel` operations rather than bypassing them.

- `DatabaseViewModel`: one database session. Authoritative for unlock/lock, save/conflict/merge, rekey, re-encryption, the authentication grace period (`secretAccess`), and the derived search/tag/AutoFill-exclusion indexes.
- `DatabaseWorkspaceState` (`DatabaseViewModel.workspace`): selection, typed `DatabaseRoute` navigation, view mode, search activation, menu request counters. No tree or secret data, no navigation objects or view references.
- `DatabaseEditorCoordinator`: editor activation, dirty-editor registration, draft submission, save/delete completion, Save and Lock. `EntryEditViewModel` / `GroupEditViewModel` own only field state, validation, and the payload they emit.
- `AppSettingsViewModel`: preference persistence and its live effects on open sessions.
- `AppRoutingCoordinator`: launch order, queued database routes, incoming-URL classification, pending TOTP enrollment, Open/Close Database transitions.
- `EntrySecretAction`: every reveal/copy disclosure that follows device-owner authentication.
- `DatabaseListViewModel`: the database list and all pending-upload draining (`drainPendingUploadsOnAppActive()`); a session never drains.

## Invariants

### Lock, unlock, authentication

- Every lock calls `ClipboardService.clearOwnedContents()`. `preservingClipboard` is the single exception and only iOS backgrounding sets it (copy, switch apps, paste). Regression-prone; macOS has no expiring pasteboard, so a missed scrub leaves the secret there.
- `lock()` clears all session state (keys, `sessionKeyFileData`, binary pool, draft, attachment preview files, workspace). Clear any new session state there too.
- An async session operation captures `lockCycleID` before its first await and publishes nothing in memory if it changed, or session secrets reappear behind the lock screen. Persisted state mirroring a completed write (keychain, reference, upload markers) still updates.
- An unlock attempt sets its outcome only while `finishUnlockAttempt` accepts its `prepareForUnlock()` token, so a late YubiKey answer or slow KDF cannot unlock behind a lock. The token is not `lockCycleID`, which paces biometric auto-unlock once per lock.
- `secretAccess` ends on `lock`, every `lockRequest` (even one that unsaved work defers), backgrounding, and the start of each unlock attempt. An unlock that finishes in the background does not open it.
- `isLockPending` is true from a deferred lock request, a window-close prompt, or Retry Save and Lock's write until the lock completes or is cancelled. The Mac SSH agent offers no key while it is set. `attachmentBytes(for:)` is the synchronous attachment read the agent uses; it moves the bytes off the main actor itself.
- While a conflict reload or Sync Now replaces the open tree, `state` is `.unlocking` but `isReplacingOpenDatabase` keeps the session open to lock triggers; they must still lock.
- A YubiKey session (`sessionUsesHardwareKey`) is read-only: a save rotates the KDF salt and would need a fresh response. Quick Launch stores the pre-key, never the response-bearing composite key.
- `DatabaseOpenFailure` diagnostics carry no file names, paths, or user data (`privacyNote`, `sanitized(_:)`). Hardware-key failures never count toward the lockout.

### Save, conflict, sync

- Stage edits through `DatabaseDraft` plus `save()`. Never mutate `rootGroup` and rebuild save state afterwards.
- `mergeAndSave()` gates its write on the conflict's `remoteSHA512` (the bytes it merged), not `openTimeSHA512`. Every failure leaves the draft and the conflict standing.
- `mergePendingUploads()` drops upload markers only after `.saved`; `.changeUnidentified` must never suggest Discard.
- Rekey and re-encryption refuse a dirty draft, an in-flight save, and cloud references with pending upload markers (draining them afterwards reverts the remote). The rekey stamps `lastMasterKeyChangeAt` so the drainer refuses older markers.
- `save()` no-ops behind an in-flight save. An operation holding `isSaving` (rekey, re-encryption) flushes edits that landed behind it; `importEntries` refuses to start.
- `syncCloudNow()` never discards unsaved work, never applies a response older than a save that finished mid-sync, never swaps a YubiKey session, and never pushes pending uploads.
- A completion arriving while a save conflict is on screen is held by `EntryEditCompletionGate` until `isSettled`. Reporting it races the conflict alert, which presents from the editor, and loses the dismissal.
- A successful new-entry save reports `.created` with its stable UUID; failed writes and unresolved conflicts report nothing, and Save and Lock keeps its ordinary completion without opening an entry.
- `DatabaseEditorCoordinator` guards submission and completion by lock cycle, and completion also by editor lifetime, so an old save cannot close a new editor. A failed create keeps its entry UUID so a retry updates rather than duplicates.
- `AppRoutingCoordinator` applies an Open/Close destination only after the source session locks; Keep Editing or a replaced source drops it.
- Custom-icon management validates the live unlocked, writable session and refuses edits during saving or a conflict. Reads include the draft so a failed save retains visible names/deletions for retry.

### Selection, search, tags

- Recycle Bin recovery validates the live source and destination at submission. A known valid previous parent restores directly; otherwise the caller presents destination options. Restore edits use the ordinary draft/save/conflict flow and derived indexes.

- `workspace.entrySelection` is one session-wide set of picked entry IDs; it survives navigation, prunes entries that leave the tree or enter the recycle bin, and ends on lock, reload, or read-only transition. `moveEntries` stages one draft and refuses read-only sessions before mutation.
- While bulk selection is active, Mac single-entry edit/copy/Return and entry or group Delete commands must be unavailable. `commandEntryID`, `canEditSelectedEntry`, and `deletableSelection` share that gate.
- A permanently deleted entry's `selectedEntryID` is not cleared by `synchronizeSelections()`; the mounted detail view closes itself. Clearing it in the deleting update unmounts the detail column and wedges a pushed editor (`../Views/AGENTS.md`). A recycled entry still exists, so `deleteEntry` / `deleteGroup` clear it at once.
- `autoFillExcludedGroupIDs` resolves `<EnableSearching>` in the same inheritance order as `KPGroup.autoFillEntries`. Change both together or search and AutoFill disagree.
- Entries under an excluded group leave the search corpus but stay in the tag index and browsing lists.
- Re-including a group writes an explicit `True`, never `inherit`, or a group inside a hidden parent cannot be turned back on. An untouched `GroupEditViewModel` switch replays the stored value, because the payload is absolute.
- `effectiveTags(for:inheritedGroupTags:)` feeds both the tag index and the searchable text; `sortedGroups(_:)` orders every folder list (recycle bin pinned last). Do not add a second path for either.
- Mac menu commands only raise a `workspace` request counter. `canEditSelectedEntry` and `deletableSelection` decide both enablement and action so they cannot drift, and Delete stops at the request so the confirmation cannot be bypassed.

### Stale completions and forms

- Custom-field protection follows each editor row through rename and reorder. Payloads explicitly specify protection, preserving hidden credential metadata; reusing a former protected name does not protect a new row.
- `EntryEditViewModel.additionalURLs` owns writable `KP2A_URL_<n>` rows. Empty or protected fields remain custom fields; a new row takes the first unused name, and `customFieldsOutsideURLRows(of:)` keeps the detail screen from listing a URL twice.
- `EntryEditViewModel` keeps imported non-Base32 TOTP bytes through unrelated edits. Explicit URI enrollment replaces those bytes even when its Base32 text matches the old field's text; later period, digit, or algorithm edits may drop the verbatim URI but must not restore the old bytes.
- `EntrySecretAction` and `AttachmentLoadCoordinator` publish only while the request and the caller's session check are current. Invalidation allows a fresh request without letting the old completion finish or clear it.
- `MacQuickSearchViewModel` holds no entry data: it reads the live session on every access and re-checks it after the password prompt.
- `commitPendingTag()` is never called from the tag field's setter (rewriting a focused field drops keystrokes), and `normalizedTags()` includes the pending token. Both editors share these rules.
- `AppSettingsViewModel.reload()` reads persisted values without replaying effects.

## Tests

Unit classes in `../../KeeForgeTests/` are named `<Type>Tests`. Cover success, failure, cancellation, and stale completion there; keep UI tests for presentation, bindings, and focus. Non-obvious mappings:

- `DatabaseViewModel` by concern: `DatabaseViewModelTests`, `DatabaseViewModelCloudSyncTests`, `AutoLockTests`, `HardwareKeyUnlockTests`, `SecretAccessGateTests`, `SortOrderTests`, `PendingUploadDrainerTests` (rekey marker cutoff).
- `PasswordImportViewModelTests` is in `PasswordImportTests.swift`; `CloudFileBrowserViewModelTests` covers `CloudFileBrowserSession` and `CloudFolderBrowserViewModel`.
- `DatabaseOpenFailure` has no class of its own: `DatabaseViewModelTests` and `FeedbackSubmissionServiceTests`.
- Editor save/reopen and failed-write retry: `KDBXCompatibilityTests`. Held completion in the real UI: `SaveConflictMergeUITests`.

## See also

- `../AGENTS.md`: shared-source changes, workflow ownership, KDBX compatibility
- `../Views/AGENTS.md`, `../App/AGENTS.md`: the shells that adapt this state and run auto-unlock
- `../Models/AGENTS.md`, `../Services/AGENTS.md`: `DatabaseDraft`, merge, save paths, pending uploads
- `../../KeeForgeTests/AGENTS.md`, `../../KeeForgeMac/SECURITY.md`
