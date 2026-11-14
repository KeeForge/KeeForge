# Cloud journal and durable creation draft

This dependent slice adds cloud save ownership and create-only recovery on top of the local replacement contract. It does not replace the local owner protocol, add a provider, change KDBX, or establish release readiness.

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

`CloudJournalDecision` supplies pure admission/allowed-transition/effect decisions. Storage and provider adapters perform effects. Record generations and exact snapshots provide CAS; stable commit leases live outside the removable payload directory. Unresolved attempts cannot be discarded by hash equality or supersession. A merge transfers captured source identities into the durable merged payload before dropping sources.

Valid cached bytes remain readable when recovery fails. Mutation uses strict journal enumeration, including unknown schema/IO failures. Sync-down cannot overwrite a pending cache. Cache publication rechecks captured epoch/date and local revocation; Keychain publication also checks the exact parsed/committed ciphertext. Coordination precedes immediate try-list/try-commit acquisition on the reverse-lock path; contention releases resources instead of waiting. Keychain-only effects cannot reenter the registry. Legacy reference cleanup runs after release.

Local uncertainty, removal tombstones, admission and source-epoch fences remain intact. No permanent target pin or antirollback guarantee is added after settlement. A freshly authenticated restored file retains the ordinary product semantics.

## Create-only ownership

Creation retains verified encrypted payload bytes, then a paused versioned intent, before dispatch. It records attempting durably before one provider call. A response supplies the actual remote identity and is persisted before durable cache/registry publication. Publication failure retains the receipt and ciphertext for explicit reconciliation; it does not justify creating again.

Every foreground creation remains paused for discovery after abandonment/restart. Cancellation reaches its worker; a late response is recorded but cancellation is checked before registration. Activation/draining never resumes creation automatically. Explicit resume is available only before an attempt or after a confirmed receipt. Unknown attempts with no identity are never converted to absence or blindly resent. Until resolved, writes to that provider/account are conservatively blocked, while cached reads remain possible.

Cloud account settings expose Cloud Recovery without session secrets. Export verifies the exact retained payload SHA and produces encrypted KDBX bytes, using the original factors. Export neither resolves a request nor authorizes removal. Reference-only selection keeps the uncertain request and its ciphertext; normal open may authenticate the selected file, while uploads stay fenced. Known completed creation replay preserves later reference/head/epoch/cache changes instead of reinstalling the creation snapshot.

## Draft limits

- Unknown creation offers explicit selection of an existing remote file as a reference only. It retains the original attempt/payload and upload fence, does not invent a receipt or claim quiescence, and does not enable uploads. There is no destructive forget/resend shortcut. Provider-specific proof/resolution beyond this read/export path is unfinished.
- The older injected AutoFill marker orchestration and drainer fallback remain to be migrated out of their legacy test fixtures. Production defaults use the new local-saver journal and journal delivery. The obsolete `applyUploadedBytesAfterSave` test surface still needs removal with replacement production-boundary coverage.
- Existing cloud saver tests that assume immediate upload need a deliberate queue/delivery contract migration. Newly authored regressions and source typechecks do not establish that those older expectations pass.
- Cloud key-publication coordination and full cache hashing are synchronous at the caller. The fence has no provider IO and uses immediate lock attempts, but this is not a UI responsiveness guarantee for large/blocked local cache IO.
- Shared registry serialization outside the fenced operations is process-local. This slice does not add global cross-process list transactions/CAS or redesign registry read failures.
- FTP, weak WebDAV validators and large OneDrive uploads retain their provider limitations. Provider responses do not establish physical durability; retained bytes do not establish remote quiescence.
- Native layouts, provider/device behavior, power-loss recovery and test runtime remain unvalidated by source-only checks. This is a reviewable draft, not an accepted implementation.
