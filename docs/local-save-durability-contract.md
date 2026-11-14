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

Ordinary local saves use this same admission with an explicit ordinary-save purpose
and empty source receipts. Admission is durable before encryption and the final
coordinated accessor validates its token, baseline, epoch and revocation. Opaque
adapter errors and interrupted/cancelled operations retain recovery even when the
old target is still observable; observing old bytes is not permission to resend.
Initial admission distinguishes an unpublished write from an observed publication
whose sync or coordinator completion failed. The latter retains its exact token
and returns a terminal pre-replacement recovery warning before encryption; it is
not a generic retryable failure. The same form invocation cannot submit again.
An actual known replacement records its existing typed TargetCommit on that same
empty admission. A future explicit save may replace it with a fresh operation UUID
only after exact target identity/SHA, baseline, epoch and revocation checks. Known
unconfirmed output is not an automatic resend permission or a new rekey; receipts
and unknown outcomes cannot use this path. Durable completion releases the empty
admission, while an affirmative pre-replacement proof permits a future retry only
if the release itself succeeds. A failed or visible-unconfirmed release reports a
pre-replacement recovery warning and keeps remaining ownership honestly. A fresh
attempt retains at most one flat prior ordinary-commit proof inside this same
admission. Affirmative pre-replacement release restores that exact prior operation
instead of erasing its unresolved durability. A new known commit drops the prior
proof; a new unknown outcome retains the barrier and cannot use the prior proof to
retry. This is bounded unwind context, not a replay history or another journal. Explicit snapshot-scoped
discard remains separate from export and never discards an unlocked draft.

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

A rekey completion can publish or invalidate Keychain items only while its actual
installed commit still owns the current admission or settled epoch and its exact
ciphertext remains the current target. Both completion checks run on a background
worker. Snapshot the list briefly, release list lock before bookmark resolution,
coordination and full ciphertext reads, then inside the protected target/registry
accessor acquire list only by an immediate try and acquire owner. Contention
rejects the attempt and releases resources without a blocking fallback or retry.
This explicit coord -> try-list exception prevents waiting on a list holder that
itself needs those coordinated resources. The registry reference, target identity
and ciphertext are checked with coordination/list/owner held through the effect. The byte
comparison uses the ciphertext already carried in the nonpersisted commit receipt,
with no KDF, KDBX parsing or hashing in this fence; legacy field cleanup runs afterwards
by CAS. Epoch/factor equality or inode equality alone does not authorize a completion.
The same boundary protects the final session-application check after asynchronous
association settlement. A late receipt
from an earlier rekey cannot overwrite or delete a later epoch's composite or
express key. Unknown local outcomes have no receipt authority to mutate those
items. Association publication and later session application also reject a
superseded receipt; a lock cycle alone is not cross-session authority.
A thread-safe per-attempt RAM permit atomically transitions pending -> claimed or
pending -> closed. Timeout/cancel closes pending before its result is delivered;
a subsequent lock or new unlock also closes it. A worker reaching the real effect
under owner after closure cannot write Keychain items. If already claimed,
interruption is terminal uncertainty until evidence of worker completion, not
cancellation/no-effect/retry proof: held resources remain owned until actual IO
finishes and existing committed recovery ownership is not released by the wrapper.
The worker never synchronously calls MainActor, including legacy cleanup. The
interrupted MainActor path does not refresh the list and direct secret/timer lock
never waits on worker/list/owner. Already-claimed synchronous Keychain IO can still
hold list and delay other list consumers; this is not a global UI responsiveness
or native/provider latency guarantee.

The fence captures its cycle only after the saver returned a known commit. An
earlier lock therefore still permits persistent-key reconciliation without session
secret restoration. A later lock revokes pending permission; a new unlock also
invalidates the original action UUID before refresh, preventing an old action from
creating a permit on behalf of the new session. Original save-cycle checks remain
mandatory for all session-secret application.

After durable witness retirement, a fresh authenticated read of a restored file
still follows main semantics. Only an old completion must match its own current
receipt bytes; this check introduces no persistent target pin or restore barrier.

Target evidence is one typed state: confirmed, unconfirmed, planned or
ready-to-retire. Live completion and recovery share the same final transition;
a planned write cannot inherit the previous file's confirmed durability. The final
coordination decision must downgrade the returned receipt and stored evidence
consistently. No generic exception establishes pre-replacement failure.

| State | Permission / completion |
| --- | --- |
| Unknown, planned, admitted, key publication or retirement unresolved | Preserve ownership; never infer idle from timeout, mismatch, missing payload or owner read/decode/permission failure |
| Known installed unconfirmed target with durable key epoch/association, or a known ordinary commit with empty receipts | Keep exact target/baseline evidence; permit a future explicit same-epoch save with a new UUID, stop automatic repeat/rekey and warn about file durability |
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

Database-bookmark renewal captures the reference/owner epoch before resolution and
updates only that bookmark using reread/CAS; it cannot roll back newer factors,
master-key dates, preferences or removal. Replacement and witness retirement share
the same primary-target resolver, including a KeeForge-only database in the cache.

Local AutoFill reads bind ciphertext and source identity under coordination. Final
quick/express-key publication holds list-lock then owner flock through the
keychain-only helper, validating the pre-read epoch, current reference, read SHA
and active target evidence. Blocked publication still permits filling valid parsed
credentials. The helper's policy/interval/Keychain callees never enter the database
list or owner; expected legacy metadata is cleaned separately by field CAS after
release. A cleanup failure retains metadata and cannot undo keychain effects. A new
read after full durable retirement follows main, without a permanent target pin.

An ordinary commit can refresh or invalidate the separate AutoFill cache using only
the exact known ciphertext from its actual receipt. If recording the positive
observation fails, the synchronous cache effect may still use that live receipt
bound to the same admission/UUID/intended SHA; a later generic read cannot. Unknown
outcomes have no such receipt authorization, and accepted sources remain protected.

App unlock uses the same final key-publication authority as AutoFill: pre-IO lease,
read-bound identity/SHA, current reference/epoch and revocation under list lock then
owner flock through keychain-only effects. Legacy metadata cleanup follows by field
CAS outside flock. A late old parse remains readable but cannot publish stale keys
after another session rekeys and retires; a fresh read after full settlement retains
main semantics. Created-session initialization uses its verified creation snapshot
and captures ownership before target observation; cloud publication is unchanged.

Newly created sessions receive the exact ciphertext already authenticated by the
creation service in the same single current RAM slot used by opened sessions.
Encrypted draft export therefore works before the first save/backup, including a
first-save failure before backup and subsequent loss of the primary cache. Export
verifies the full snapshot and binary pool, preserves the draft, and clears the
context on lock; it creates no additional persisted key or ciphertext history.

Quick-unlock master-entry dates keep the shipped shared-UserDefaults dictionary
format. Local worker rekey and app/cloud/extension persistence serialize all
in-process date reads and read/modify/write operations through one security-owned
leaf mutex, including conditional first entry and per-reference removal used by
list clear. That mutex takes no list/owner lock and calls no Keychain operation;
expiry releases it before deleting items. Missing dates retain their existing
policy, and interval selection remains the separate shared setting. This is not
cross-process atomicity: app and extensions have distinct mutexes, and the current
UserDefaults dictionary can still lose simultaneous updates across processes.
No cross-store Keychain/date transaction or durability/power-loss proof is added.

## Bookmark renewal during a local read

A supported stale-bookmark renewal changes only that field through its existing CAS. Successful durable publication can return an in-memory receipt binding the exact before/after references, captured owner epoch and coordinated target identity. No failed, visible-unconfirmed, contended or revoked publication mints a receipt. It is not persisted and contains no secret material. A reader may carry it to cache or key publication only while the actual registry equals that exact after-reference and the original epoch, factors, hardware, source/admission and revocation checks still pass. A final read-key effect additionally holds coordination over the authenticated ciphertext and registry through immediate try-list, owner validation and keychain-only publication. Changed inode or ciphertext rejects the effect. Local writes and their output-cache publication resolve without renewing bookmarks, preserving their own commit and epoch boundaries.

Provider resolution/coordination and ciphertext IO occur in the existing bounded worker outside list lock. Lock, cancellation and a superseding read close pending permission. If Keychain IO already claimed permission, timeout reports uncertainty and cannot revoke its possible effects or restore session secrets later. Memory lock/AutoFill cleanup remain independent of that worker; a claimed Keychain call can still delay other registry-dependent work. AutoFill can fill authenticated credentials after rejected or uncertain key persistence, with registry-dependent switch/mutation actions withheld for the uncertain request. A created local session retains its authenticated RAM ciphertext and draft-export capability without invoking the cloud persistence callback as a substitute for local read authority.

A known write publishes or invalidates its output cache against the installed target identity and ciphertext in its existing commit receipt. It does not select a different source by resolving the pre-replacement bookmark again. The current registry observation, owner epoch, pending-source barriers and exact target/ciphertext checks remain mandatory; an unknown write supplies no installed receipt.

Unlock installs the session key-file factor with its unlocked payload before awaiting
read-key persistence. Post-await work still requires that original action UUID:
a same-session rekey can supersede the unlock without changing the lock cycle.
AutoFill distinguishes observed worker termination without a claim from pending
timeout and claimed uncertainty. Only the first releases its matching live-request
latch after a terminal rejection; cancellation or revocation does not reopen it.

A known commit receipt binds bytes and target identity, not sandbox authority.
Pending-merge completion keeps the resolved bookmark grant open through source
retirement, cache refresh and stale-cache invalidation, without renewing it during
the transition. The original-file coordination is released before cache publication
takes registry authority. Injected scope-lifetime observations exercise this order
with real storage; signed external-file sandbox grants remain device validation.

During an ordinary save, completion observes the already granted resolved location
of that same operation rather than choosing another location through a new bookmark
resolution. Pending-merge follow-up reads and cache/fingerprint/reload auxiliaries resolve
without renewal or Documents heal, so they cannot invalidate their own captured
reference; all source, epoch, target and reference guards still apply. Read-only replacement errors after entry can remain indeterminate with intact
observable bytes and a retained admission: permission error types alone are not
affirmative proof that replacement never happened, and a retry cannot encrypt again.

Known rekey factors may reach the originating session before registry publication.
Legacy metadata cleanup still compares its captured pre-save registry observation
after the authorized Keychain effect, never the already updated RAM factors/date.
The comparison may fail honestly after a concurrent change; it does not adopt that
change or remove a newer alias.

No-renew resolution performs no ownership capture or persistence. It can return a
valid moved target, but a broken bookmark requiring Documents fallback returns
unavailable and a resolved Trash location remains Trash. Neither outcome authorizes
overwrite, cache removal or a fictitious missing-file conclusion. Default resolution
retains the shipped Documents heal; that visible field-specific registry update has
no established fsync proof and does not construct a durable renewal receipt.

An authenticated opening read retains its historical reference through final
publication. Its own receipt may update only that bookmark in the originating RAM
session after the owner/target/reference fence succeeds and the action/cycle/current
reference still match. Normal registry metadata refresh cannot supply a different
bookmark, master-key date, key-file association or hardware configuration as new
authority.

Durable bookmark-renewal admission also requires both the source ledger and on-disk
source enumeration to be empty, under the same owner lock. Pending, provisional or
untracked sources defer the registry transition rather than weakening the final
read-key/cache fence or promoting a reference from a failed publication callback.
Resolution still returns a valid observed file without a receipt. The session and
registry therefore keep the same bookmark through merge/save/consume; a later fresh
read can renew after ownership is idle. Admission, retirement, key-publication,
owner-read and revocation failures continue to reject renewal without inventing
quiescence or changing source ownership.

Sources may arrive after the durable renewal accessor returns. That renewal remains
a bookmark transition, not permission to publish old read keys. A separate read-only
reconciliation validates its exact before/after reference, captured owner epoch,
coordinated target identity and authenticated ciphertext. Healthy eligible sources
may remain during this check; provisional, missing, unknown, admitted, retiring or
revoked ownership rejects it. The unchanged session action/cycle may then apply only
its own bookmark field before the normal merge obtains a fresh admission and new
installed commit receipt. Neither the old renewal target nor this observation grants
a write, cache refresh or source consumption. If proof fails or times out, sources
remain owned and local recovery is presented; no merge is attempted with the stale
reference. The pre-renewal empty-source gate and final read-key/cache guards remain.
