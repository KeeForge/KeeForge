# Local save durability

This contract covers file replacement and its app/AutoFill callers. Cloud journaling,
database-list transactions, durable cloud creation and Google Drive are separate changes.

## Outcomes

| Outcome | File state | Caller behavior |
| --- | --- | --- |
| Failure before replacement | Original remains authoritative | Keep the previous SHA, key and association; report failure |
| Unknown replacement effect | Do not infer original or new bytes | Keep recovery ownership; terminal warning, no automatic resend |
| Conflict at the coordinated baseline check | Foreign bytes remain untouched | Reconcile the returned bytes before another save |
| Durable replacement | New ciphertext installed and file/directory synchronization completed | Apply its SHA, keys, association and cache; complete the requested operation |
| Committed replacement with unconfirmed durability | New ciphertext installed, but directory sync or coordination failed afterwards | Apply committed state and show a terminal warning; do not repeat encryption or claim durable completion |

The committed outcome must be recorded inside the coordinated accessor before a
later coordination error can escape. Retain the existing baseline check and backup
before replacement. Encrypt and verify off the main thread. Staging and backups use
the common durable writer in an existing extension-safe persistence file; its use
must not introduce a cloud queue dependency.

## Applying a committed result

Both committed outcomes describe the exact installed bytes. Advance the session's
hash/tree and the new key/key-file association after rekey, including necessary
persistence after the initiating session locks. Preserve lock-cycle checks so a
late result cannot resurrect unlocked secrets or erase newer edits. Refresh the
separate AutoFill cache, or invalidate an older copy if refresh fails.

Persisting an association must have an observable outcome. If it fails after file
replacement, retain the committed key and report the recovery requirement; never
pretend the old key still opens the installed file or repeat the rekey automatically.

The warning is a completed invocation requiring acknowledgement. Master-key and
encryption-settings forms must not leave their original Save action able to repeat
the committed request. Future changes require an explicit new operation. Ordinary
save loops stop on the warning and retain edits that arrived during the operation.

AutoFill updates its installed state but must not report durable password save,
creation or passkey registration, or publish new identities as successful. Retain
pending local merge sources until ownership is safely established; a warning must
not cause the same source to be encrypted again on each activation. Expose a
supported recovery action instead of a silent retry loop.

## Evidence and limits

Tests cross the real staged-write, coordinated replacement and cache boundaries.
Cover pre-replacement staging failure; replacement followed by failed directory
sync or coordination; cache refresh failure; ordinary save with concurrent edits;
rekey across lock with new-key reopening and key-file association; settings forms
with one invocation; and AutoFill/pending-local-source retention and recovery.
Count encryption/replacement calls independently and verify the bytes that remain.

Use a local KDBX compatibility scenario that reopens the installed ciphertext with
the new key and preserves the full semantic snapshot. Exercise both app targets and
their extension-safe source lists. Translate every new message in all shipped
locales and use the existing focused localization gate.

An fsync result is an operating-system protocol result, not a physical power-loss
experiment. File replacement, database-list updates and Keychain updates are not
one atomic transaction in this layer. A crash between them can require the new
password/key file or restoration from the old encrypted backup. Do not claim a
recovery journal that this layer does not implement. Native signed app/AutoFill,
Keychain and power-loss validation remain separate from headless CI evidence.

## Pending-local admission and ownership

Pending local sources stay in their existing store, including throughout recovery.
An operation first obtains a durable admission containing an operation UUID, exact
source receipts (immutable identity and SHA-512 of the bytes actually merged), the
target baseline, and the observed master-key-change date. Admission precedes the
saver. There is no automatic replay after admission survives an interruption.

| State / event | Next state | Automatic save permitted |
| --- | --- | --- |
| Idle, exact inputs still owned | Admitted | One invocation using its token |
| Admitted, durable saved output includes the receipts | Consume those sources and resolve admission | A future new operation |
| Admitted, affirmative typed pre-replacement failure or conflict | Resolve admission, retain sources | A future retry |
| Admitted, warning, unknown error, cancellation or crash | Recovery required (an interrupted admission has the same restriction) | No |
| Recovery, explicit export | Unchanged; export reads the exact receipt, never mutable cache | No |
| Recovery, separate confirmed destructive discard | Consume only the confirmed receipt snapshot and resolve its admission | A future new operation |

A missing payload or unreadable checkpoint is a recovery state, never an empty
store. Export works while locked and warns that each source is a complete encrypted
snapshot requiring its original key. A failed export neither authorizes nor claims
discard; a separate destructive decision can resolve irreparable records honestly.
Sources added after a snapshot are excluded from that snapshot's discard/cleanup.

A stable per-database flock protects exclusive immutable source creation, receipt
validation, admission transitions, retirement and revocation. The lock order is
DatabaseListStore's process lock -> pending-local flock; pending-local code never
acquires the list lock. Parsing, KDF and awaits run outside flock. The final local
replacement accessor acquires that same flock, validates the admission token and
permanent removal tombstone, and holds it through replacement. Removal either
precedes that accessor and prevents replacement, or follows the completed replace;
it cannot invalidate a check and then allow a late replacement. Coordination is
acquired before flock, and removal never enters file coordination while holding it.

Removal revokes future writes durably. Unresolved sources/checkpoints require an
explicit recovery/discard decision before reference removal can finish; generic
list removal is not consent to destroy AutoFill changes. Revocation and recovery
metadata survive removal attempts, so stale add/finalize paths cannot recreate
payloads. Database-list transactions and cross-process list CAS remain outside
this cut; a list write failure must remain observable and cannot undo revocation.

Ownership, source publication, admission and truthful local save outcomes form one
integrated guarantee. A helper or ownership subcommit alone does not implement this
contract and is not a complete candidate.

## Effect boundaries for source publication

| Event | Shared copy | Bookmarked original | Source ownership / caller |
| --- | --- | --- | --- |
| Durable provisional intent, payload write not confirmed | Unchanged | Unchanged | Recovery-only source; never eligible for automatic merge |
| Durable provisional payload | Unchanged | Unchanged | Prepared handle; preparation alone is not acceptance |
| Known coordinated shared-copy replacement | Contains the intended ciphertext | Unchanged | Activate the exact prepared source |
| Source acceptance confirmed | Contains the intended ciphertext | Unchanged | Accepted AutoFill change awaiting app write-back |
| Acceptance published, later sync unconfirmed | Contains the intended ciphertext | Unchanged | Terminal warning with committed shared-copy state; no durable registration/save completion |
| Shared-copy replacement effect indeterminate | Unknown | Unchanged | Keep provisional source in recovery; do not activate, discard, or resend automatically |
| App merge admitted before its saver invocation | Unchanged until replacement | Guarded by captured identity/baseline/epoch | A surviving admission prevents another automatic invocation, including for newly arrived sources |

Only an affirmative observation before replacement can establish a pre-replacement
failure. An exception after entering a replace operation is not that proof. Source
acceptance never proves that the bookmarked original was updated. Recovery copy
must identify the affected storage boundary instead of calling a prepared source a
replaced database file.

Recovery entries retain independent identity observations when their bytes cannot
be read; healthy sources remain exportable. Destructive resolution of an irreparable
entry or owner record validates device, inode, stat and safe parent identity under
the same owner lock. An unavailable observation never becomes proof of absence.
Foreground refresh updates an already-open locked Details screen independently of
SHA changes or process-local notifications. Export and discard remain separate
operations; removal requires explicit discard after any desired exports.

## Durable cleanup and visible publication

A durable merge output is re-observed under target coordination and owner flock
before consumption: installed identity and SHA must still match its receipt. Only
then may the exact admitted sources be removed. Each unlink and removal of an empty
source directory is synchronized through its changed ancestors inside the App Group
anchor. A partial failure retains the admission, even if some payloads are now missing.

Publishing idle is the last step after all admitted receipts are durably absent.
Failure before that publication retains recovery. An observed idle rename followed
by failed final synchronization is `resolvedVisibleWithoutConfirmedDurability`:
other processes can see idle, but the removed receipts cannot be automatically
reencrypted. A crash that revives the older checkpoint requires manual recovery
for its missing receipts. Sources outside the admitted set remain owned and intact.
The caller acknowledges a cleanup-record warning, without claiming target-file
uncertainty when the output itself was durably saved.

## Key publication and witness retirement

A local master-key change starts with no pending sources/admission. Its last
coordinated accessor repeats that check under the owner lock and publishes the
key barrier before replacement. Sources arriving during it keep their original
ciphertext/epoch and cannot automatically drain under the new key.

Target evidence is one typed state: confirmed, unconfirmed, planned or
ready-to-retire. Live completion and recovery share the same final transition;
a planned write cannot inherit the previous file's confirmed durability. The final
coordination decision must downgrade the returned receipt and stored evidence
consistently. No generic exception establishes pre-replacement failure.

| State | Permission / completion |
| --- | --- |
| Unknown, planned, admitted, key publication or retirement unresolved | Preserve ownership; never infer idle from timeout, mismatch, missing payload or owner read/decode/permission failure |
| Known installed unconfirmed target with durable key epoch/association | Keep exact target/baseline evidence; permit a future explicit same-epoch save, stop automatic repeat/rekey and warn about file durability |
| Target and current association durable, required receipts consumed durably, no remaining sources | Publish ready-to-retire certificate with the new epoch; synchronize that owner record before withdrawing the witness |
| Ready certificate | Retire by owner/epoch/revocation CAS, preserving later work; replay does not require the same target SHA again |
| Minimal owner publication visible but final sync fails | Terminal bookkeeping warning; other processes may see idle, so do not simulate rollback or claim every reader retains the witness |
| Fully durable retirement | Resume main's ordinary open-time baseline/conflict/merge/reload behavior; no permanent key-target pin remains |

The ready certificate is minted only after actual target durability, a durable
field-specific association proof, source namespace/receipt retirement and the
correct owner operation/epoch have been established. Its owner epoch must be
synchronized before witness withdrawal. A surviving certified record may reconfirm
its own file/namespace and resume withdrawal without rereading an externally edited
or restored target. A planned/unconfirmed record without that certificate cannot
use this path. Mutation still rejects stale epochs, revoked identities and unknown
owner state. Withdrawal removes only target evidence, never new sources/admissions,
source epochs or the stable lock/tombstone.

This cut deliberately provides no permanent cryptographic antirollback guarantee
against external restoration after fully durable settlement. A user who restores
an older database and opens it with its correct key gets main's normal behavior.
The retained epoch continues to reject old actors and source receipts; it is not
an assertion that the externally selected file must always use the last key.

Key-change association publication holds list lock, combined original/registry
coordination, then owner flock through the field write. It validates the exact
installed target before publishing factors. Ready certification rechecks current
reference/association under the same order and synchronizes the actual registry
file/namespace before publishing the certificate. No owner-lock to list-lock path,
await, KDF or parsing is allowed under flock.

## Preferences and cache publication

Idle Select/Clear uses a field-specific reread/CAS setter, not a stale whole-reference
update or a new persisted owner workflow for identical-value preference ordering.
UI generation/cancellation guards reject late actions. Automatic stale bookmark
renewal uses the same field setter. During actual key/preference recovery, exact
desired association intent/proof and operation/epoch CAS remain; an active admission
or key barrier cannot be overwritten. No preference changes the master-key date,
crypto key, source epoch or pending source ownership. Cloud preferences affect only
the local registry and do not create pending-local ownership or provider work.

All local cache entry points, including scanner, add, heal/relink, migration,
creation and VM unlock/refresh, use the local publication fence. External reads
capture reference/epoch before IO and cannot adopt newer ownership afterwards.
Publication holds the current reference lock, original/cache coordination and owner
flock; it rechecks actual bytes, epoch and revocation. During recovery only matching
proven output can be published, and pending snapshots/unique recovery ciphertext
must survive rejection. Late reads after remove cannot recreate the old cache.
Scanner fingerprints advance only after accepted cache publication. The legacy
migration path is limited to the shipped legacy cache and an unobserved epoch;
new-reference initial publication cannot bypass tombstones or active ownership.

Fully settled ordinary external file restoration uses main's cache semantics;
this fence does not reintroduce permanent rollback protection after retirement.
Cloud provider caching remains on its existing path. Global database-list read
failure redesign/transactions and cloud engines remain outside this cut.

## Recovery presentation and draft export

Database Details exposes Export Unsaved Changes for the same unlocked local dirty
session independently of owner/witness availability, including unreadable ownership.
One authenticated encrypted context may remain in RAM until lock/new unlock; known
commit receipts can provide the already-produced ciphertext. There is no prior
witness history or external-adoption operation. Export uses the existing local
encoder/native presenter, verifies the reopened full document/binary pool off main,
checks cycle/revision/cancellation and preserves the draft on every outcome. The
copy requires the session's key and is distinct from a retained encrypted source.
Read-only formats retain their existing restrictions. Missing compatible context
or failed verification reports failure and never produces a fake copy.

Source exports remain exact identity/hash-verified ciphertext and work with the
vault locked when the OS permits file access. A surviving key-publication admission
can export only a matching intended-output cache copy; that is not proof the
original was saved and never releases admission. Export never authorizes deletion.
A separate destructive confirmation covers only its captured snapshot and may
resolve irreparable entries honestly without claiming an export succeeded.
Abandoning a mismatched key record is a separately captured destructive choice
that revokes future writes; source-only discard does not silently abandon a known
key epoch. Neither action discards the unlocked draft or consumes later sources.

After durable retirement, normal Merge/Reload/conflict-copy actions work as in main.
During active local recovery their VM entry guards run before merge or draft discard;
the alert offers Database Details/recovery and encrypted draft export instead of
promising a successful write or discarding edits into an unresolved mutation gate.
Safe reading and recovery export remain independent of mutation permission.

## Validation boundary

Authored filesystem and caller regressions cover real publication/replacement
faults, admission/receipt ownership, certificate replay/withdrawal, stale cache reads,
scanner/heal/relink paths, ordinary no-witness draft export, active conflict guards,
terminal forms and normal post-settlement interoperation. The local new-key
compatibility scenario reopens installed bytes and compares the full snapshot.
Static checks and build-for-testing cannot establish runtime assertions. Signed
native layout, Keychain/device grants and physical power loss require separate
validation; no test host/app/runtime is executed by this worker.
