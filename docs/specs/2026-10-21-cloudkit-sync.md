# App-managed iCloud sync: feasibility and proposed contract

Date: 2026-10-21. Related issue: [#192](https://github.com/KeeForge/KeeForge/issues/192).
Baseline reviewed: `3c84144` on `main`.
Status: proposal for review; no CloudKit capability is enabled by this document.

## Recommendation and feasibility

Use whole, encrypted KDBX 4 files as CloudKit assets in the user's private
database. This preserves KeeForge's parser, writer, history, attachment pool,
unknown XML, master-key configuration, and merge boundaries. Entry-per-record
sync would require another persistence format and a second conflict model; it
would expose entry structure unless a new encryption protocol were designed.
Do not introduce that format for this feature.

Use CKSyncEngine for change discovery and scheduling, with a durable local
outbox owned by KeeForge. Apple's API availability covers iOS/iPadOS 18 and
native macOS 15. Scheduling is opportunistic, so the UI must offer explicit
refresh and report the last confirmed server acknowledgement. Availability of
the API establishes technical feasibility, not verified product support.
See [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5).

Conditional record writes provide the required conflict primitive:
[`ifServerRecordUnchanged`](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged)
rejects an outdated record change tag with `serverRecordChanged`. Keep the
fetched record's system fields; never reconstruct a fresh record to replace an
existing vault or fall back to `allKeys`/`changedKeys`. Verify CKSyncEngine's
record-provider path preserves this behavior in the two-writer integration
spike before enabling writes. Apple's
[working sample](https://github.com/apple/sample-cloudkit-sync-engine/blob/main/SyncEngine/SyncedDatabase.swift)
shows retaining system fields and handling send failures; its example conflict
resolution is not KeeForge's vault merge policy.

## Proposed support matrix

Every row below is a target contract, **unverified on signed devices**. Ship no
platform capability until its independent acceptance checks pass. Unsupported
OS versions keep the existing deployment floors; there is no public/shared
CloudKit database, web client, or non-Apple CloudKit client in this proposal.

| Capability | iPhone / iPad, iOS/iPadOS 18+ | Native Mac, macOS 15+ |
| --- | --- | --- |
| Setup | Explicit enable with the current system iCloud account | Same; both Mac distribution channels use the same production container |
| Discovery | Fetch private custom-zone changes; choose a vault to download | Same, independent of Files or a synchronized Finder folder |
| Unlock | Existing password/key-file/hardware-key rules; credentials stay local | Same; user supplies factors on each device |
| Download and writable sync | Encrypted KDBX asset; conditional record replacement; recoverable conflicts | Same; signed sandbox and Developer ID checks required |
| Offline access | Downloaded encrypted copy opens; edits enter a durable outbox | Same; no guarantee of background delivery |
| AutoFill | Shared encrypted cache; durable pending saves; main app uploads | Same cache boundary; extension gains no CloudKit or network authority |
| Export and leave | User-selected KDBX export; explicit keep-local/remote-removal choices | Same using the native save panel |
| KDBX 3.1 | Remains read-only; no writable sync enrollment | Same |

## Data, identity, and encryption

A new opt-in import creates a random vault identifier. The record ID combines
that identifier with the account-specific custom zone. A device's local
DatabaseReference UUID remains its local cache/Keychain identity; discovery maps
remote identity to that UUID and never matches by filename or nickname. Importing
the same file twice creates two independent vaults unless the user explicitly
selects an already discovered vault. A KDBX root-group UUID is not a cloud identity.

Proposed record fields are a schema version, encrypted KDBX CKAsset, opaque
mutation UUID for acknowledgement recovery, deletion state, and an optional
user-chosen label in `encryptedValues`. No entry titles, URLs, usernames,
passwords, composite keys, key-file contents, biometric credentials, or decrypted
vault contents become CloudKit fields. If an encrypted label is unavailable,
show a generic vault label rather than treating the entire vault as absent.

CloudKit's [private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)
requires an iCloud account and consumes that user's storage quota. KDBX encryption
is the vault confidentiality boundary regardless of CloudKit encryption. Apple's
[encrypted-fields and asset protection](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)
adds a separate iCloud Keychain dependency; do not promise that it makes every
identifier, relationship, timestamp, size, or traffic pattern secret. Do not
synchronize unlock credentials through CloudKit or enable iCloud Keychain sync
for existing KeeForge Keychain items as a side effect.

A downloaded vault requires its original factors. Key files are selected locally
on each device and are never included in the asset. Hardware-key sessions retain
the existing read-only save restriction. Locked sessions may transport already
encrypted files but cannot merge or invent replacement credentials. Record IDs,
account identifiers, labels, asset URLs, and file contents stay out of logs.

## Persistence and existing owners

Current integration points are
[`DatabaseReference`](../../KeeForge/Models/DatabaseReference.swift),
[`DatabaseViewModel`](../../KeeForge/ViewModels/DatabaseViewModel.swift),
[`SharedVaultStore`](../../KeeForge/Services/Persistence/SharedVaultStore.swift),
[`CloudSyncCoordinator`](../../KeeForge/Services/Cloud/CloudSyncCoordinator.swift),
[`PendingUploadQueue`](../../KeeForge/Services/Cloud/PendingUploadQueue.swift), and
[`KDBXMerger`](../../KeeForge/Models/KDBXMerger.swift).

A CloudKit sync service in the main app owns the engine and account namespace.
Discovery is a separate responsibility from a provider's `listFiles` picker;
CloudKit should not pretend to be a remote directory tree. Reuse the session's
existing draft, encryption, conflict, backup, and merge operations through an
explicit storage destination. Do not create an independent save path in a view,
and do not simply add a provider enum case while leaving discovery/account
lifecycle implicit.

Persist fetched record system fields, account binding, immutable encrypted
outbox payloads, base revision, payload hash, mutation ID, and engine state.
Engine serialization is an optimization for delivery, not the only record of
unsent work. Apple requires saving
[state updates](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/stateupdate/stateserialization)
for the next engine initialization. Write local transactions before registering
engine work; on restart reconstruct pending work from the durable outbox.
Maintain the app's existing App Group isolation and per-file coordination so an
AutoFill process cannot race a cache replacement.

## Enable, sync, conflict, and recovery workflows

1. **Enable:** require an unlocked, supported vault with no unsettled save or
   pending extension changes. Explain the encrypted local/remote copies and
   independent unlock factors. Persist the encrypted snapshot and pending
   enrollment before creating its remote record. Show Pending until server
   acknowledgement; retries use the same remote and mutation IDs. Cancellation
   before submission creates no remote vault. An uncertain submission remains
   recoverable and is reconciled before enrollment is removed.
2. **Discover/open:** fetch remote metadata for the current account, let the user
   download a chosen vault, then use the normal unlock path. A cached open is
   explicitly offline/stale when freshness cannot be established. A new remote
   file is not published over a newer cache or unacknowledged extension save.
3. **Save/offline:** first durably commit the newly encrypted local bytes and
   their outbox operation against the fetched base revision. Only then report a
   local save as successful, with Pending visible. Keep timestamped encrypted
   backups before any replacement. Upload the immutable payload using the
   record's original change tag. An acknowledgement clears only the exact
   operation/hash it confirms; a newer save stays queued.
4. **Concurrent change:** on `serverRecordChanged`, retain both encrypted
   versions. Download the actual winning asset if the error's record lacks
   usable asset bytes. Do not auto-select a winner by modification time. Unlock
   the remote with the current factors, then offer KeeForge's existing merge
   only if its binary-pool and key constraints allow it. A merge is another
   conditional save against the fetched remote record; another race conflicts
   again. Refusal offers encrypted export/recovery of both sides.
5. **Uncertain success/interruption:** never drop the outbox merely because an
   upload returned no reply. Fetch the record, compare its mutation ID and
   encrypted payload hash with the sent operation, and acknowledge only an
   exact match. A different head remains a conflict; preserve the sent bytes
   even if a later writer already replaced them. Retry transient failures with
   backoff; quota failures keep Pending and offer storage/retry/export actions.
6. **Master-key change:** serialize against every save/outbox operation. Resolve
   or durably quarantine old pending writes before publishing the new-key
   asset. Other devices retain their local versions and ask for the new factors
   rather than uploading an old-key copy. An old-key cache cannot silently
   replace a new-key remote. No background merge crosses a key boundary.

## Account changes, deletion, and leaving sync

Bind each engine, outbox, record cache, and callback to a local account epoch.
Before the first upload at launch, reconcile the system account with the stored
binding; a callback from a previous epoch can update neither the active account
nor its cache. Stop delivery and lock affected sessions on sign-out or change,
withdraw their AutoFill identities, and retain encrypted pending work under the
old binding for explicit recovery. Never move an old account's outbox into the
new account. Returning to the old account requires a fresh fetch before retry.
Apple documents that an
[account change resets engine pending state](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange),
including account transitions while the app was not running. Temporary account
unavailability pauses delivery; it is not a request to delete local data.

Separate **Remove from this device**, **Stop syncing and keep a local vault**,
and **Delete from iCloud on all devices**. Keep remote data for the first two.
For stopping sync, export/commit a local KDBX and resolve any pending local
changes before switching its reference to local; show that the remote copy
continues independently. If export fails, enrollment stays intact. A normal
export is a snapshot and never silently tracks later external edits. To bring
external edits back, use an explicit import-as-new or validated merge workflow.

Remote deletion uses a conditional tombstone while retaining the encrypted
asset for recovery until the user explicitly confirms permanent removal. A
receiving device with pending edits keeps them as recoverable local work and
must not recreate the deleted record automatically. A missing zone, keychain
reset, or manual iCloud purge enters recovery: preserve local/outbox bytes,
explain loss of remote availability, and require an explicit decision before
recreating or deleting anything. This deliberately avoids unconditional
re-upload after Apple's encrypted-data-reset recovery procedure; another device
may hold a different pending version. Define a retention period and remote
storage cost in the product decision before implementation.

## AutoFill and product state

Extensions read only the existing App Group encrypted cache. App-managed sync
adds no extension entitlement, CloudKit call, OAuth flow, or network request.
An extension save must persist its immutable payload and account/base-revision
binding before reporting success; adapt the current two-phase pending-upload
contract rather than assuming a mutable cache path is a complete outbox.
The main app alone adopts and uploads those operations. Retain freshness and
pending-save notices, including on Mac where the app may not have run recently.

Use existing vocabulary for Offline/Cached, Pending, Conflict, and failures.
Show last successful remote acknowledgement separately from last local save.
A conflict retains local and remote recovery actions; offline without a cache
explains that a first download is needed. Sign-in/account, quota, permission,
key change, and remote deletion errors have distinct actionable recovery. Later
implementation localizes new copy in all nine shipped locales and validates
VoiceOver, focus, keyboard access, and iPad/native Mac presentation.

## Validation required before implementation can ship

| Contract | Focused deterministic coverage | Signed integration evidence |
| --- | --- | --- |
| Enable/discover/open | Idempotent creation, cancelled/uncertain enrollment, duplicate labels, stable mapping | Two iPhones or iPhone+iPad plus native Mac; production-container discovery across both Mac channels |
| Save/conflict | Two writers from one change tag, merge refusal, repeat races, all failure paths retain both versions | Real CKAsset uploads with overlapping writes; export opens in another KeePass client |
| Durability | Kill at every outbox/cache/engine-state boundary, lost acknowledgements, newer-save acknowledgement isolation | Offline edit, force quit, restart, reconnect and quota/rate-limit recovery on each platform |
| Account boundary | Sign-out/change while queued or uploading, stale callbacks, A→B→A while stopped | Disposable accounts; no upload, AutoFill disclosure, or identity publishing across accounts |
| Deletion and keys | Tombstone racing a save, missing zone, encrypted-key reset, rekey with pending extension edits | Multi-device delete/recovery and changed-factor unlock with retained old local versions |
| AutoFill/cache | Two-phase save, concurrent replacement backups, stale cache, pending adoption and account binding | Real iOS and native Mac AutoFill panels, with the main app initially terminated |
| Portability/exit | Export failure preserves enrollment; explicit import and non-mergeable copies | KDBX export with attachments/history/unknown XML; leave sync and reopen elsewhere |

Extend the owning shared unit suites and KDBXCompatibilityTests, run focused
KeeForgeTests and KeeForgeMacTests, both external KDBX gates, relevant app builds,
and the smallest native UI smokes. Unit fakes cannot establish CloudKit's real
conditional-commit, entitlement, notification, or cross-device behavior.

## Decision and delivery gates

Proceed to a signed development-container spike only after review of the
whole-file model, local durable outbox, metadata/privacy contract, deletion
retention, and explicit export/leave behavior. The spike must prove conditional
CKAsset replacement and account isolation before any writable capability is
exposed. Then deliver in working layers: opt-in enrollment/discovery/download;
durable local saves and safe conflict recovery; extension adoption; lifecycle
and deletion recovery. Each exposed layer needs its full platform checks.

The current [threat model](../threat-model.md) and
[Mac security boundary](../../KeeForgeMac/SECURITY.md) were reviewed. This proposal
changes no running architecture. An implementation must update both for the
CloudKit destination, metadata visibility, account epochs, outbox writers,
AutoFill freshness, encryption-key reset, notifications, and signing/capability
changes; refresh AppGroupGuardrailTests if the shared write surface changes.

No signed CloudKit experiment, account connection, capability change, app build,
or runtime test was performed for this design. The support matrix remains a
proposal. The issue should remain open for the product decisions and subsequent
implementation; this document does not claim native iCloud sync is implemented.
