# Local save durability

This contract covers file replacement and its app/AutoFill callers. Cloud journaling,
database-list transactions, durable cloud creation and Google Drive are separate changes.

## Outcomes

| Outcome | File state | Caller behavior |
| --- | --- | --- |
| Failure before replacement | Original remains authoritative | Keep the previous SHA, key and association; report failure |
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
