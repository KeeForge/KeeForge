# Journal for existing cloud databases

This dependent slice adds cloud replacement ownership and recovery on top of the local replacement contract. It does not replace the local owner protocol, add a provider, change KDBX, or establish release readiness.

## Replacement ownership

Before replacing a cloud cache, retain immutable intended ciphertext and a durable marker containing its SHA-512, captured local head/epoch and predecessor baseline. Local replacement retains its known-commit, unconfirmed-durability, indeterminate and affirmative-conflict outcomes. The app may finish a local save while provider delivery is pending. AutoFill uses the same extension-safe journal without provider access.

| Persisted state | Allowed effect | Failure/restart |
|---|---|---|
| Legacy finalized | Preserve exact hash-matching payload before overwrite | Unidentified legacy records block mutation |
| Prepared | Prove the cache contains the intended ciphertext, then finalize | Baseline/foreign/missing cache is recovery, not permission to repeat encryption |
| Ready | Check current head/epoch and remote base; persist attempt before dispatch | Reliable matching revision/hash avoids a full download; uncertainty does not |
| Attempting | Await that invocation's response | Generic error, cancellation, absence, changed revision or equal bytes retain uncertainty; no automatic resend |
| Proven rejected before commit | Persist affirmative rejection, then permit another attempt | Generic exceptions never supply this proof |
| Confirmed | Reconcile exact cache, durable registry state and ancestry | No provider request; retain ownership if any step fails |
| Retired | Marker namespace synchronized before payload cleanup | A replayed confirmed record can only reconcile; payloads are not deleted before marker removal is durable |

`CloudJournalDecision` supplies pure admission/allowed-transition/effect decisions, delivery eligibility and confirmed head/epoch/descendant reconciliation. Adapters execute the declared dispatch, acknowledgement and retirement effects. Metadata equality skips a byte download only when the adapter identifies its revision as content identity, or a recorded content digest matches; weak WebDAV/Last-Modified equality is insufficient. FTP’s hash revision avoids repeating its full-content probe. Storage and provider adapters perform effects. Record generations and exact snapshots provide CAS; stable commit leases live outside the removable payload directory. Unresolved attempts cannot be discarded by hash equality or supersession. A merge transfers captured source identities into the durable merged payload before dropping sources.

Valid cached bytes remain readable when recovery fails. Mutation uses strict journal enumeration, including unknown schema/IO failures. Sync-down cannot overwrite a pending cache. Cache publication rechecks captured epoch/date and local revocation; Keychain publication also checks the exact parsed/committed ciphertext. Coordination precedes immediate try-list/try-commit acquisition on the reverse-lock path; contention releases resources instead of waiting. Keychain-only effects cannot reenter the registry. Legacy reference cleanup runs after release.

A confirmed journal cannot be discarded, including a conflicted record whose local reconciliation failed. Only confirmation recovery can retire it after durable target/reference/ancestry proof. A missing modern immutable payload fails mutation closed; it never supplies an empty owner observation.

An explicit sync/reload with pending work downloads a read-only remote snapshot, leaving the cache and source namespaces intact. Sync Now offers divergent bytes to the existing merge action. Reload retains the draft and asks for that merge before replacing it. Merge authenticates the remote and captured source snapshots, writes against the exact reconciled remote SHA, and conditionally transfers only those unchanged source identities after a durable local output; confirmed/unknown work retains its own owner. A reconciled byte baseline does not inherit validators associated with the prior reference, so delivery verifies remote bytes before conditional dispatch. This byte check is still required when the reconciled baseline equals the predecessor/cache SHA; that equality does not bind the old reference content hash to it. Optional express-key effects defer while any journal owns delivery; normal originating-session edit bookkeeping still completes for a known durable queued save.

An open session Z can reconcile an AutoFill source/cache A with remote B without treating either SHA as the other baseline. The real parser/merger authenticates all captured sources and B; a restricted, nonserialized single-invocation context binds the before-reference, exact cache A identity/SHA, source generations, local owner epoch and operation UUID. The saver revalidates that authority before encryption and under its final coordinated replacement fence. The remote B SHA is recorded separately and does not inherit old validators. A subsequent coordinated handoff checks the real durable installed output and the same exact source set before transferring ownership to the new journal. Concurrent sources, changed cache/reference/epoch, cancellation before claim or an unconfirmed output retain the old sources; the context cannot authorize a Keychain write, another invocation, or adoption of arbitrary current bytes. A claimed write may complete despite cancellation, so lack of a callback is never no-effect evidence.

A metadata CAS mismatch during cloud open, Sync Now or automatic foreground refresh never imports the current epoch, factors or head into an older authenticated snapshot. The old snapshot may remain readable with its historical tuple, while its final key-publication fence rejects changed authority or removal. An independent fresh authentication of a restored file after full settlement keeps the ordinary product semantics.

A merge queues its enqueue notification in the same RAM operation context and emits it only after handoff has exited all coordination/list/commit/owner locks; final action cleanup emits it if handoff was skipped. The callback is consumed once, without a persisted notification state. Ordinary-save notification timing is unchanged. This prevents that notification from waking a drainer into its own not-yet-completed handoff; independent lease contention still rejects the preclaim operation and retains sources, and no retry or reencryption is inferred from it.

Local uncertainty, removal tombstones, admission and source-epoch fences remain intact. No permanent target pin or antirollback guarantee is added after settlement. A freshly authenticated restored file retains the ordinary product semantics.

## Draft limits

- AutoFill delegates journal ownership to the local saver; draining always uses journal delivery. Recovery coverage verifies exact cache and immutable payload bytes across confirmation, backup failure, uncertainty and removal.
- App and AutoFill execute cloud key-publication coordination, full cache hashing and keychain-only effects off the main actor. The original action/cycle permit closes before claim on cancellation or timeout; a claimed effect is uncertain until the worker finishes. A deadline does not stop OS IO or establish no effects. Legacy registry cleanup is separate and CAS protected after lock release.
- Legacy finalized markers without an authenticated remote baseline may be exported with their original factors for manual reconciliation; even a matching revision does not authorize blind delivery. Their retained source is not silently discarded or treated as a proven remote base.
- Shared registry serialization outside the fenced operations is process-local. This slice does not add global cross-process list transactions/CAS or redesign registry read failures.
- FTP, weak WebDAV validators and large OneDrive uploads retain their provider limitations. Provider responses do not establish physical durability; retained bytes do not establish remote quiescence.
- Native layouts, provider/device behavior, power-loss recovery and test runtime remain unvalidated by source-only checks. This is a reviewable draft, not an accepted implementation.

Creation and conflict-copy creation retain the shipped create-only paths and their existing limitations; this journal covers replacement of existing databases only.

Replacement content requests in Dropbox and OneDrive never internally resend after a lost response; OneDrive create-only retries and read/session-setup policies retain their shipped behavior. A single current PUT rejected with HTTP 412 (WebDAV/OneDrive), or an FTP mismatch before target installation, supplies affirmative evidence only for that invocation. FTP install/restore failures and arbitrary mapped conflicts supply no such proof.
