# Epic: Edit Support v1

## Summary

Add the ability to create, edit, and delete entries in KDBX databases (local and Dropbox-backed) from both the main app and the AutoFill extension, with strong-password generation, lossless preservation of unknown XML nodes, and block-on-conflict semantics for cloud sync. KeeForge has been read-only since launch; this epic is the first time the app writes back to disk.

## Clarified requirements

The questions asked during clarification and the answers that shaped this spec.

- **Q:** What scope of edits should ship in v1?
  **A:** Entries only. Add/edit/delete entries — title, username, password, URL, notes, custom fields, TOTP. The group tree stays read-only in v1; entries can only be added to groups that already exist.

- **Q:** When the user saves a credential into a Dropbox-backed database from the AutoFill extension, how should v1 push the change to Dropbox?
  **A:** Investigate KeePassium's approach first. Findings:
  - KeePassium uses iOS's `FileProvider` system for cloud storage rather than linking the Dropbox SDK directly into the extension, so its extension reads and writes via `FileDataProvider`/`NSFileCoordinator` against whatever URL the system Files app exposes. For Dropbox-via-Files this is transparent upload; for other providers it's whatever that provider's FileProvider extension does.
  - Critically, KeePassium *also* persists each edit as a `PendingDatabaseTransaction` to **Keychain** (not App Group files) via `DatabaseTransactionManager`, *before* attempting the upload. The transaction is a list of typed operations (`CreateEntryOperation`, `EditEntryOperation`, `AddEntryURLOperation`). On the next main-app open, queued ops replay if the immediate-save attempt failed. The keychain choice gates access to logged-in users and benefits from the iOS data-protection class.
  - KeePassium's AutoFill extension hardcodes its conflict-resolution callback to `.cancel` (`KeePassium AutoFill/AutoFillCoordinator+dbSaving.swift:38–48`), uses a 10-second timeout, and skips the QuickType-refresh post-save task. KeePassium has a "Recovered Entries" fallback group for ops whose original parent group has been deleted by the time the queue is replayed — out of scope for v1's block-on-conflict model.
  - This pipeline has been the source of multiple shipped database-corruption bugs (KeePassium CHANGELOG: lines 15, 1656, 2494, 1495, 1437, 986/988, 708, 1459 — the most recent as of Nov 2025: *"Longer saving of AutoFill changes could corrupt database"* in 2.5.171). Anything we ship in slice 07 must be defended by atomic writes, exhaustive round-trip tests, and a marker model that is durable before the extension returns.
  - Since KeeForge already integrates SwiftyDropbox in the *main app* but not the extension (`project.yml:82–99`), and we have no FileProvider integration for Dropbox, we adopt this mapping: **the extension performs an immediate save against the local cache via `LocalDatabaseSaver` (slice 04) — that is the equivalent of KeePassium's "immediate save attempt" — and additionally enqueues a small marker in App Group storage so the main app can drain the upload to Dropbox on next scene-active.** The encrypted bytes already live in the cache, so the marker does not need to carry the edit payload; this avoids putting plaintext secrets in App Group files. A `CFNotificationCenterGetDarwinNotifyCenter` post on enqueue (matching Strongbox's `AutoFillDarwinNotification`) lets a foregrounded main app drain immediately. We do not add SwiftyDropbox to the extension target. A future slice could add direct extension upload via raw Dropbox HTTPS, but it is out of scope for v1.

- **Q:** If the remote Dropbox copy has changed since the user opened the database, what should v1 do at save time?
  **A:** Block + offer reload or sibling copy. Detect via remote rev / SHA512 of bytes captured at open time. Block the save; user picks "Reload and re-edit" (drops local changes) or "Save as conflict copy" (writes a sibling `name (conflict 2026-04-06).kdbx`). No merge logic in v1. This matches KeePassium's behavior.

- **Q:** How should the v1 writer handle XML elements the current parser doesn't model?
  **A:** Strict round-trip. Instrument `KDBXXMLParser` to capture unknown nodes verbatim into an opaque sidecar attached to each `Entry`/`Group`/`Meta`. The writer re-emits them. Editing in KeeForge never silently drops attachments, custom icons, custom data, or unknown KP2A fields written by KeePassXC or KeePass2Android. **Cribbed from Strongbox** (`model/keepass/BaseXmlDomainObjectHandler.m`'s `lazyUnmanagedChildElements` + `unknownHeaders` + `writeUnmanagedChildren`), explicitly *not* from KeePassium — KeePassium's writer drops unknown XML, and that design choice is the root cause of multiple "lost data after editing on iOS" reports against them.

## Stable Core Impact

This epic intentionally touches the stable core. `AGENTS.md` lists the following as stable: `KDBXParser.swift`, `KDBXCrypto.swift`, `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, `TOTPGenerator.swift`.

- `KDBXParser.swift` — must be instrumented to capture unknown XML nodes (slice 01). This is unavoidable: a writer that drops unknown elements would corrupt the user's data on the first save.
- `KDBXCrypto.swift` — gains symmetric write helpers (encrypt-CBC, encrypt-ChaCha20, gzip) alongside the existing decrypt/decompress helpers (slice 02). No changes to the existing functions.
- `Entry.swift` and `Group.swift` — gain an `unknownXML: OpaqueXMLNodes` sidecar property and stop being purely `let`-only (slice 01). The change is additive: existing readers stay correct.
- `EncryptedValue.swift` — no signature changes; existing `encrypt(_:using:)` is sufficient for re-encrypting on edit.
- `TOTPGenerator.swift` — no changes.

Tests: every stable-core change is gated by a focused test added in the same slice (`KDBXParserRoundTripTests`, `KDBXWriterTests`, `EntryUnknownXMLTests`).

## Slice plan

| #  | Slice                                                  | File                              | Depends on |
|----|--------------------------------------------------------|-----------------------------------|------------|
| 01 | Lossless XML round-trip (parser + serializer)         | `01-xml-round-trip.md`            | —          |
| 02 | KDBX writer (encryption, framing, HMAC)               | `02-kdbx-writer.md`               | 01         |
| 03 | DatabaseDraft + typed edit operations                  | `03-database-draft.md`            | —          |
| 04 | Local file save with backups and conflict detection   | `04-local-save.md`                | 02, 03     |
| 05 | Cloud save (Dropbox write scope + push)                | `05-cloud-save.md`                | 04         |
| 06 | Entry edit UI in main app                              | `06-main-app-edit-ui.md`          | 03, 04     |
| 07 | AutoFill save / generate + pending-upload queue        | `07-autofill-save.md`             | 03, 04, 05, 06 |

**Why this split?** Each slice is shippable in isolation: 01–02 land a working KDBX writer with no UI; 03 is a pure model addition; 04 makes saving work for local databases (a complete user-facing beta); 05 extends save to cloud; 06 adds the main-app UI; 07 wraps the extension story. The phased rollout reads naturally as 01→02 (foundation) → 03–04 + 06 (local-only edit beta) → 05 (cloud) → 07 (AutoFill). Merging 01 and 02 was tempting but the parser instrumentation alone is non-trivial and benefits from landing with its own round-trip test suite before the writer is layered on. Merging 04 and 05 was tempting but the cloud path adds Dropbox scope re-auth, optimistic-concurrency rev tracking, and network failure handling — substantial separate code paths. Merging 06 and 07 was tempting but the main-app surface and extension surface use different SwiftUI hosts and have different memory budgets.

## Cross-slice notes

- **Conflict detection token.** Every slice that touches save reads/writes a `storedDataSHA512: Data` field stored alongside `DatabaseReference` for the open session (not persisted across launches). Set on every successful open, including from the cloud cache. Compared on every save attempt against the freshly-read remote bytes. This is the KeePassium pattern (`KeePassiumLib/KeePassiumLib/DatabaseSaver.swift:206`) — provider-agnostic, and works equally for local files and Dropbox.
- **Dropbox optimistic concurrency.** Slice 05 layers Dropbox's native `mode: { ".tag": "update", "update": "<rev>" }` upload mode on top of the SHA512 check, using the rev captured at open time. **Both KeePassium and Strongbox use `mode: overwrite`** (KeePassium: `DropboxManager.swift:671`; Strongbox: `DropboxV2StorageProvider.m:263`) and rely on mtime-epsilon comparisons that have been the source of recurring sync bugs (FAT32 mtime granularity, `serverModified` jitter). Using `update(rev)` is a small but real improvement over both leaders for the "two devices edit at once" case.
- **Pending operation envelope.** Slices 03, 04, 07 share a single `EntryEdit` enum (Codable) representing the only operations v1 emits: `createEntry`, `updateEntry`, `deleteEntry`. The shape of this enum is fixed in slice 03 and reused unchanged in 07.
- **Threading.** All KDBX serialization, encryption, KDF derivation, and SHA512 work happens off the main actor via `Task.detached` — same convention the read path already follows (`AutoFillExtension/CredentialProviderViewController.swift:392–402`, `KeeForge/ViewModels/DatabaseViewModel.swift`).
- **Lock state during edit.** A draft is held inside `DatabaseViewModel`. If the inactivity timer fires or the user manually locks while a draft is dirty, the lock prompt warns about unsaved changes; if the user confirms, the draft is discarded and the lock proceeds. Slice 06 owns this UX. The draft is *never* persisted to disk in cleartext.
- **Backup policy.** Slice 04 introduces a per-database backup directory under the App Group container at `backups/{databaseId}/`. Keeps the last 5 backups. Survives app reinstall via App Group. Cloud-backed databases get backups too. Manual restore from backup is out of scope for v1; this is an undo safety net, not a UI feature.
- **AutoFill ↔ main app handoff.** The pending-upload queue (slice 07) lives at `pending-uploads/` in the App Group container. Each marker is `{databaseId, encryptedBytesCacheURL, openTimeSHA512, expectedRev, createdAt}` — deliberately *no* edit payload, since the encrypted cache file is the source of truth. The main app drains the queue on every `.scene` becoming active **and** on receipt of a Darwin notification posted by the extension on enqueue (matches Strongbox's `AutoFillDarwinNotification` pattern), so a foregrounded main app picks up the change immediately rather than waiting for the next scene cycle.
- **Dropbox write scope.** Slice 05 adds `files.content.write` to the OAuth scope request. The `DropboxCloudProvider` detects "missing scope" errors on first write and surfaces a typed save failure that explains why the account needs refreshed access.
- **Read-only mode is cross-slice.** Slice 04 adds an `isReadOnly: Bool` flag to `DatabaseReference` (Codable, default `false`) plus a context-menu toggle in `DatabaseRowView` and a save-path guard. **Slices 06 and 07 must respect this flag too:** the `Edit` button, the `+` add-entry button, and the swipe-to-delete actions in slice 06 are disabled when the active DB is read-only; the AutoFill extension's `prepareInterfaceForPasswordCreation` handler in slice 07 refuses the request with a brief "this database is read-only" alert and cancels. Each slice has a single guard point named in its scope. The pending-upload drainer (slice 07) does **not** check the flag — markers represent already-authored intent, and toggling a database to read-only after making edits cancels future edits, not in-flight ones.
- **Synced-folder safety.** Slice 04 also adds a one-time interstitial the first time the user attempts to edit a `.local`-source database whose `bookmarkData` resolves to a known third-party file provider (Dropbox, Google Drive, OneDrive, Box, iCloud Drive). The interstitial offers "Continue editing" (remembered per database) or "Keep read-only" (sets the read-only flag from above). For unknown file providers, the same interstitial fires with generic copy. This is the practical answer to the "two apps writing to the same `.kdbx` file in `~/Dropbox/`" failure mode — Strongbox sidesteps the same problem by deprecating Files-app bookmarks entirely (`StrongBox/SelectStorageProviderController.m:171`); we keep the path but warn the user when entering edit mode for the first time.

## Rollout

Sequence-of-operations checklist for shipping the epic. The agent should treat the prerequisite steps as blockers on the named slice; the post-merge steps as exit gates.

- **Before slice 05 starts:** Update the **Dropbox App Console** ([dropbox.com/developers/apps](https://www.dropbox.com/developers/apps/)) for the KeeForge app — Permissions tab → check `files.content.write` → submit. The KeeForge app is currently in Development mode, so this takes effect immediately for the developer's test accounts; no Dropbox review delay. (If this app ever moves to Production, **adding write scope will trigger Dropbox re-review** — sequence accordingly.)
- **Slice 05's launch behavior:**
  - **Reads keep working without re-auth.** Existing refresh tokens are read-scope only; they continue to authenticate file metadata fetches and downloads exactly as before. No user is locked out of their database by upgrading.
  - **Save fails gracefully without write scope.** If the user tries to save before re-authorizing, slice 05 surfaces `CloudProviderError.writeScopeRequired` with the entry's draft preserved.
- **Slice 04's read-only escape hatch (rolling-back protection).** If a user discovers a save bug in v1, they can flip any database to read-only via the `DatabaseRowView` context menu and continue using KeeForge as a read-only manager exactly like today's behavior — no need to wait for a hotfix.

## Out of scope

- **Group editing** (rename, create, delete, move, icon change). Defer to v1.1.
- **"Make a private copy" for synced-folder databases** (option (c) from the synced-folder discussion). v1 ships only the warning + read-only escape hatch. v1.1 candidate: an explicit "Move into KeeForge's container" action that copies the file out of the cloud-mirrored folder into the App Group, drops the original bookmark, and breaks the cross-app sync risk entirely.
- **Detect-known-providers list maintenance** beyond the initial set (Dropbox, Google Drive, OneDrive, Box, iCloud Drive). Third-party file providers will fall through to the generic warning by design; we are not building a maintained allow/deny list of every cloud provider on the App Store.
- **Database settings editing** (master password change, key file change, KDF parameter change, custom name).
- **Binary attachments** (the round-trip slice preserves them; they cannot be added/removed/edited in v1).
- **Custom icons.** Same: preserved on round-trip, not editable.
- **Entry history** beyond what KeePassXC writes (we preserve existing history nodes, do not append new ones in v1).
- **Manual restore from on-disk backup** — backups exist but there is no UI to roll back.
- **Multiple cloud providers.** Only Dropbox in v1; the `CloudProvider.upload` API is generic but no other implementation is shipped.
- **Direct Dropbox upload from the AutoFill extension.** Extension queues, main app drains. Future work could add raw HTTPS upload directly from the extension.
- **3-way merge of conflicting edits.** v1 strictly blocks on conflict; the user picks reload or sibling copy.
- **Web-based "save password" (KeePassXC integration / browser extension).** Not in scope.
- **Auto-save / auto-sync.** Saves are explicit user actions in v1.
