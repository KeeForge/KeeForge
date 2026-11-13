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

## Key publication is separate from source retirement

A local master-key change starts only with no pending sources or admission. Its
last coordinated accessor repeats that check while holding flock, then persists
a key-publication barrier before replacement. A source arriving during this barrier
can retain its ciphertext but cannot become eligible under the new key epoch.
Settlement never consumes such a source.

| Key publication state | Mutation permission / supported recovery |
| --- | --- |
| Barrier before replace, or unknown replace effect | Block another save/rekey; inspect the exact original target and intended SHA explicitly |
| Exact new ciphertext installed, association or epoch publication unconfirmed | Keep installed keys/SHA and barrier; confirm the installed key change in Details, or export the unlocked draft before closing |
| Exact new target, field-specific association durably published, owner epoch durable | A future explicit operation can use the new epoch and exact baseline; never repeat the rekey automatically |
| Epoch publication visible but its final sync unconfirmed | Terminal record warning; a later mutation must reconfirm the visible owner file and namespace under flock before using it |
| Epoch settled, target durability still unconfirmed | Retain target identity/SHA and this uncertainty in the owner record; warn about the file, permit a future explicit save against that exact new target |
| Restart with old, missing, foreign or differently associated target | Do not infer settlement or permit an old-key drain; safe reads remain independent and recovery requires an explicit action |

Association publication rereads and changes only the key-file fields on the
registered reference. Its durable receipt requires the coordinated writer's actual
file and in-anchor directory sync; a Boolean result from the ordinary list writer
is not this proof. Publication validates the operation/epoch under flock, without
acquiring the list lock from inside the owner. Database-list global transactions,
read-failure handling and cross-process CAS remain outside this cut.

Every future mutation reconfirms visible owner metadata under flock, checks the
current epoch/association, and revalidates the target identity and SHA in the final
coordinated accessor. A planned subsequent write is recorded before replacement;
an unknown result or failed metadata update cannot leave an older witness authorizing
another mutation. Read, fill and receipt-verified encrypted export do not require
that mutation permission. An incompatible original read must not replace a proven
new-key cache or republish an older quick-unlock key.

Details reuses the native local export presenter for a full encrypted copy of an
unlocked session's unsaved draft. It uses that session's composite key and an
authenticated ciphertext held for the session or a compatible original/backup header,
verifies reopening and the complete writer document/binary pool off the main thread,
checks the lock cycle, and never clears the draft. The copy requires the key of
that unlocked session, which can be the original key after an unknown rekey outcome.
The session holds at most its current authenticated ciphertext and one prior witness;
known save receipts can supply the installed encrypted bytes without another encryption.
These references are not serialized and clear on lock or a new unlock attempt. If no
compatible authenticated ciphertext is available, export fails and the edits remain
in the session. Export is not rollback, association settlement or consent to discard.
Abandoning an unresolved key-publication record explicitly revokes future writes;
it does not undo a master-key change already installed in the file.

Local cache refresh coordinates the original and cache before taking owner flock.
It rechecks the original ciphertext and revocation, preserves accepted AutoFill
sources and refuses stale completion after removal. Failed cache refresh invalidates
only an older copy when ownership still permits it. The lock orders are list lock
→ registry coordination → owner flock, and target/cache coordination → owner flock;
there is no flock → list lock/coordination path and no await/KDF under flock.

## Target evidence and mutable key-file preference

The owner stores one typed target state: `confirmed(snapshot)`,
`unconfirmed(snapshot)`, or `planned(previous, operationUUID, intendedSHA)`.
The same final-outcome transition handles live writes and explicit recovery.
Final coordination failure downgrades both the receipt and owner evidence;
a planned write recovered without a synchronization proof stays unconfirmed,
even when the previous target was confirmed. A confirmed receipt is never inferred
from a generic throw or from the older target's durability.

Select/Clear and automatic stale key-file bookmark renewal are same-epoch preference
changes. They never encrypt, change master-key dates, or reclassify sources. Under
list lock → combined target/registry coordination → owner flock, publication checks
the captured reference, epoch, full target witness and association generation.
A durable nonsecret preference intent records the exact desired bookmark/name
before registry publication; an active admission or key barrier rejects a new
selection. Unknown owner state is unavailable. Legacy references without a witness
keep that legitimate preference path without gaining invented key/target evidence.
Cloud references change only their local registry preference with phase-aware publication;
they never create a pending-local owner intent, admission or key epoch and make no
provider calls. Cloud save/rekey semantics remain with the existing cloud saver.

| Preference result | Ownership and presentation |
| --- | --- |
| Proven registry write not published | Release only its exact intent durably; previous preference is intact |
| Intent publication unconfirmed | Retain exact desired preference for explicit confirmation; no claim the registry changed |
| Registry publication observed, completion unconfirmed | Keep observed preference; terminal warning and explicit recovery of that exact choice, without rollback |
| Registry and owner publication durable | Update only bookmark/name/field proof and association generation; epoch, target evidence, dates, sources and admissions remain intact |

Automatic renewal captures the old field generation before resolving a fresh
bookmark and uses this same publisher. A later Select/Clear/rekey/removal invalidates
it. Read-only resolution can still return its URL when renewal cannot be persisted.
An open session refreshes only the nonsecret same-epoch preference before an explicit
save; it never adopts a new master-key epoch or restores key-file bytes from this field.

## Explicit authenticated local interoperability

A fully confirmed settled witness, with no source, admission, retirement, preference
intent or planned target, may be explicitly reconciled with a same-key external edit.
Unknown/unconfirmed target evidence cannot use this action to bypass rollback checks.
The unlocked session must authenticate both the exact prior witness ciphertext and
the current coordinated original with its composite key. SHA selects the exact bytes;
only successful parsing authenticates their key. Missing prior proof, a wrong key,
old-key rollback, read-only format or attachment-pool divergence preserves the draft
and refuses adoption. Safe reads and explicit encrypted draft export remain available.

Preparation parses/merges off the main actor without writing the target. The prepared
result binds the owner observation, epoch, association generation, exact target
identity/hash, lock cycle and draft revision. Commit holds list lock and combined target/registry coordination
before flock, revalidates the current reference, captured owner and absence of sources/pending work,
and holds coordination and flock through witness publication. Incoming sources,
preferences, removal or another writer invalidate this proof. Target synchronization
failure records a known unconfirmed target; it does not trigger an automatic save.

The session serializes adoption with save/rekey/settings. New edits, cancellation,
lock or dismissal invalidate the request. If edits arrive after owner commit, keep
them and refuse to install the stale merge. The authenticated ciphertext may remain
as bounded session context, but no late callback restores secrets after lock.
Adoption updates the target witness/baseline without changing the key epoch, factors
or master-key date. A dirty draft keeps its exact real edit log without replay;
its base is the authenticated current-file tree/meta/pool and its current state is
the validated merged tree. Discard restores that current file; a later explicit Save
writes both sides. With no edits, adoption keeps a clean current-file session.
Neither adoption nor its warning encrypts or replaces the database.

## Validation boundary

Authored regression tests exercise real filesystem publication and replacement
with external write/fsync/coordination faults, source ownership, explicit export and
discard, session lock and draft growth, terminal forms, and AutoFill callers. The
password-only compatibility artifact uses the real local saver and reopens its
installed output with the new key before comparing the full semantic snapshot.
Static parse/typechecking cannot establish these runtime assertions. Signed native
layout, Keychain/device behavior and physical power-loss behavior require separate
validation; no local app or test-host execution is part of this implementation run.

Details also checks a key witness against the current original independently of
unlock/SHA notifications. A readable older file may open without gaining mutation
permission. A saved encrypted cache copy is exportable while locked only when its
hash matches the captured key witness (or its pending same-epoch write) and its
identity stays unchanged across the read under coordination/flock. This is an
explicit verified copy of known ciphertext, never a substitute for a pending-source
receipt or permission to consume it. A surviving master-key admission can similarly
export only a cache copy matching its exact intended SHA and current operation.
That encrypted output is not proof that the original was saved; it requires the
key chosen for that operation and never resolves admission. A missing, foreign or unreadable copy reports
export failure and grants no discard permission.

Publishing a key-change association coordinates the registry and original target
in one accessor before taking owner flock. The accessor rereads the current
reference, validates operation/epoch and the exact compatible installed target,
and holds both resources through association publication. A preliminary inspection
is not publication authority; a cooperating replacement between inspection and
publication is either excluded by coordination or rejected without changing the
registry. Recovery never publishes new factors to discover whether they fit an
old, missing or foreign target. Settlement independently revalidates afterwards.
