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
