# KeeForge Security Audit — 2026-08-01

This document is a point-in-time archive of a repository-wide security review,
its threat model, the findings that survived review, and the remediation completed
immediately afterward. It describes the source at the revisions below; later code
may differ.

| Item | Revision |
| --- | --- |
| Audited source | `64419db4de0991638cc1925fb4ad4123ac24e299` |
| Remediation | `529807b2170c64f6b94f7c9c070e997cc0e43eee` |
| Audit mode | Whole repository, static analysis, medium effort |
| Remediation status | Six canonical issues fixed and regression-tested |

## Executive Summary

The original scan reported twelve findings: two high, six medium, and four low.
That count reflected repeated reports of the same code paths. After consolidating
by root cause, the result is six distinct issues:

1. one high-impact key-file derivation failure;
2. one conditional AutoFill domain-boundary issue;
3. two low-severity crash/denial-of-service conditions; and
4. two defense-in-depth gaps involving physical access to an already-unlocked
   device, a scenario explicitly excluded by KeeForge's `SECURITY.md`.

The most important defect was in composite-key derivation. A key file recognized
as XML but rejected during validation could be silently omitted. During
key-file-only database creation this produced the public constant
`SHA-256("")`; with a password present it reduced the selected protection to the
password alone. The fix makes key-file processing fail closed at the shared
derivation boundary.

The other issues involved an incomplete public-suffix list used to publish
AutoFill identities, two Swift runtime traps on unusual KDBX/passkey values, and
inconsistent device-owner authentication around entry editing and deferred locks.
All six were addressed in `529807b`, with focused tests on iOS and macOS and one
targeted iOS UI test.

I reviewed the audited revision and fixing commit directly, reconciled the raw
findings with the repository's security policy, and ran the remediation test
passes described below. I did not execute the original scan's proposed exploit
scenarios against the vulnerable revision. In particular, Apple platform behavior
for a credential identity registered directly against a public suffix was not
validated end to end on a physical device.

## Scope and Methodology

### Repository coverage

The scan divided the repository into twelve components:

- KDBX core models and cryptography;
- cloud synchronization services;
- the AutoFill extension and shared AutoFill services;
- security services, including Keychain, device-owner authentication, passkeys,
  and screen protection;
- persistence, bookmarks, key files, database creation, and shared storage;
- application-support services such as clipboard, favicons, and feedback;
- view models;
- SwiftUI views and application lifecycle code;
- the experimental macOS app;
- the vendored Twofish implementation;
- tests; and
- build configuration, CI, and developer tooling.

Five categories were intentionally excluded or treated as non-product material:
test fixture data, derived/vendor build artifacts, the historical `docs` archive,
agent workflow definitions, and generated Xcode/icon metadata. The living macOS
security note was still considered as product context. All seventeen top-level
directories were accounted for by either a scanned component or an explicit
exclusion.

### Review process

The original static scan used this pipeline:

1. inventory the repository and partition it into security-relevant components;
2. build one threat model per component before finding discovery;
3. dispatch 49 independent source reviewers across the component/category matrix,
   plus a breadth sweep;
4. normalize 54 candidate findings into 43 candidate sites;
5. send each candidate through a three-lens verification panel, requiring at least
   two positive votes to survive; and
6. render the twelve surviving reports with source locations, preconditions,
   impact, and proposed fixes.

The panel completed 128 of 129 planned votes. The missing vote belonged to a
candidate already rejected by its other two voters and did not affect any reported
finding. Every reported finding received a complete panel.

This was a static process. Agent agreement improved review pressure but was not
runtime proof. No application, test, exploit, or proof of concept was run during
the original scan.

### Cleanup and remediation review

The follow-up review treated the scanner output as claims rather than as final
issue boundaries. We regrouped findings by vulnerable code path:

- F1, F2, F3, F4, and F7 were one key-file derivation defect;
- F5 and F12 were one entry-editor visibility/copy defect; and
- F9 and F10 were one passkey length trap.

F6, F8, and F11 were already distinct. This reduced twelve reports to six
remediation units without dropping any reported behavior.

Each unit was then compared with `SECURITY.md`, the vulnerable source, the fixed
source, direct callers, and focused regression tests. The cleaned classifications
below reflect source reachability, the actual trust boundary, required
preconditions, and what was or was not executed.

## Consolidated Threat Model

### Protected assets

The review treated the following as the primary assets:

- master-password and key-file-derived composite keys;
- per-session keys and the decrypted entry tree;
- passwords, TOTP seeds/codes, passkey private keys, and attachment plaintext;
- KDBX confidentiality, integrity, and save compatibility;
- Keychain items shared between the app and AutoFill extension;
- encrypted database copies and metadata in the App Group container;
- AutoFill identity metadata and origin-to-entry matching decisions; and
- cloud revisions, bookmarks, and pending-upload state used to avoid overwrites.

### Principal trust boundaries

| Boundary | Untrusted or less-trusted side | Control expected at the boundary |
| --- | --- | --- |
| File picker/cloud/cache → KDBX parser | Local, imported, shared, or cloud-hosted bytes | Format bounds, KDF limits, authentication, safe parsing |
| Key-file bytes → composite key | User-selected raw/XML file content | A supplied factor is incorporated or rejected; never omitted |
| Authenticated KDBX XML → in-memory model/writer | Content authored by whoever controls a valid vault | Safe model construction and total serialization even for unusual values |
| Website/app → AuthenticationServices → AutoFill extension | Service identifiers, record identifiers, passkey requests | Correct origin matching before secrets are released |
| Main app ↔ App Group ↔ AutoFill extension | Cross-process encrypted files, bookmarks, settings, queue markers | KDBX authentication, narrow shared-state formats, Keychain ACLs |
| Device owner/lifecycle → unlocked vault | Scene changes, inactivity, reveal/copy requests | Device-owner authentication and complete lock-state transitions |
| Cloud/network → sync layer | Provider responses, revisions, WebDAV metadata and bytes | TLS/provider authentication, conflict detection, bounded parsing |

### Attacker capabilities considered

Depending on the component, the review considered an actor able to:

- supply a database or key file that a user chooses to open;
- author content inside a shared vault while knowing its valid credentials;
- control a sibling site or hosted tenant involved in an AutoFill request;
- modify cloud-hosted encrypted bytes through a separate cloud capability;
- influence operating-system callbacks, file-provider results, or persisted
  cross-process state; or
- obtain an encrypted database after it was created.

The review did not assume that a remote website can directly rewrite encrypted
KDBX XML, that a malformed file bypasses KDBX authentication, or that an actor can
open a locked vault without its credentials.

`SECURITY.md` places vulnerabilities in the iOS/macOS apps, AutoFill extensions,
KDBX implementation, Keychain/App Group storage, and cloud/network features in
scope. It excludes third-party service flaws, KDBX format weaknesses rather than
KeeForge implementation defects, jailbroken-device scenarios, and issues requiring
physical access to an already-unlocked device. That last exclusion materially
changes the classification of the entry-editor and deferred-lock observations.

### Security invariants used during remediation

- Every supplied credential factor must either affect key derivation or fail the
  operation.
- Untrusted or authenticated-but-attacker-authored file values must produce errors
  or bounded values, never process traps.
- Credential identities must not be published at a DNS public/private suffix shared
  by unrelated tenants.
- Entry-to-origin matching is security-sensitive metadata, not merely search UX.
- Locking must clear live secrets, or resuming a deliberately deferred lock must
  establish a new trust decision.
- Stored passwords should not enter a visibly selectable editor state before the
  same device-owner check used by adjacent reveal/copy controls.

## Findings Overview

| ID | Original reports | Clean classification | Summary | Status |
| --- | --- | --- | --- | --- |
| KF-01 | F1–F4, F7 | High | Rejected XML key files could be omitted from composite-key derivation | Fixed |
| KF-02 | F6 | Medium, conditional | AutoFill identities could be published at an incomplete public-suffix boundary | Fixed |
| KF-03 | F9–F10 | Low | A 32-byte passkey value could construct a negative Swift range | Fixed |
| KF-04 | F11 | Low | Extreme KDBX timestamps could trap during save serialization | Fixed |
| KF-05 | F5, F12 | Defense in depth | Stored passwords started visible/selectable in the entry editor | Fixed |
| KF-06 | F8 | Defense in depth | Dirty drafts could defer automatic locking and resume without reauthentication | Fixed with documented fallback |

The clean classification is not a mathematical score. It records the practical
boundary and prerequisites. KF-02 remains conditional because the incorrect domain
metadata was reproduced, while cross-tenant password fulfillment still depends on
Apple's identity-matching behavior. KF-05 and KF-06 are useful product hardening
changes but fall under the policy's unlocked-device exclusion.

## Detailed Findings and Fix Results

### KF-01 — Rejected key files could disappear from key derivation

Affected paths included:

- `KeeForge/Models/KDBXCrypto.swift`
- `KeeForge/Services/Persistence/DatabaseCreationService.swift`
- `KeeForge/Models/KDBXParser.swift`
- `KeeForge/ViewModels/DatabaseViewModel.swift`
- `AutoFillExtension/CredentialProviderCoordinator.swift`

The vulnerable two-component derivation API used `try?` around
`KeyFileProcessor.processKeyFile`. Once a file was recognized as KeePass XML,
invalid decoded key length or a mismatched v2 hash raised an error. `try?`
converted that error to `nil`, and derivation continued without appending the
key-file component.

We can carry two states through that path:

- with a password, the result becomes the password-only composite key; and
- without a password, the pre-key is empty and the result becomes
  `SHA-256("")`.

The database-creation guard only checked whether non-empty bytes had been supplied,
not whether those bytes produced key material. Creation then wrote and reopened the
new file using the same weakened key, so its internal round trip could not expose
the omission.

The maximum impact required a narrow workflow: the user created a new database with
only a rejected XML key file, and another party later acquired the encrypted file.
An ordinary existing database created with a valid key file would normally fail to
unlock after that file became invalid rather than silently downgrade.

The fix makes `compositeKey(password:keyFileData:)` throwing and uses ordinary
`try` for key-file processing. Creation, parser convenience APIs, main-app unlock,
and AutoFill unlock all propagate the failure. The password-only overload remains
nonthrowing and byte-compatible.

Regression coverage verifies malformed XML with and without a password, v2 hash
mismatch, no write/registration after rejected creation, valid key-file-only
creation, and existing password/key-file compatibility.

### KF-02 — AutoFill publication used an incomplete domain boundary

Affected path:
`KeeForge/Services/AutoFill/CredentialIdentityStoreManager.swift`.

Credential identities were reduced to a supposed registrable domain with a small
hand-maintained collection of familiar multi-label suffixes. When a suffix was not
listed, the helper returned the final two labels. Representative results were:

| Stored host | Vulnerable identity | Correct identity |
| --- | --- | --- |
| `login.mybank.com.pl` | `com.pl` | `mybank.com.pl` |
| `account.example.github.io` | `github.io` | `example.github.io` |
| `github.io` | `github.io` | no registrable domain |

This placed credential identity metadata at a public or private suffix shared by
unrelated registrants. The extension's record-identifier fast path trusted the
selected identity after unlock and did not perform a second stored-host comparison
before completion.

The classification error was reproduced with focused tests. The stronger scenario
in which an unrelated sibling site receives the suggestion and then the password
depends on whether the Apple platform treats such an over-broad `.domain` identity
as eligible. That behavior was not tested on a physical device, so the report does
not present cross-origin password release as demonstrated.

The fix replaces the manual list with the bundled Mozilla Public Suffix List already
used by `CredentialMatcher`. It retains explicit IPv4, IPv6, localhost, and
single-label rejection. An initial implementation omitted the numeric IPv4 guard;
the full owning test class caught `192.168.1.1` being reduced to `1.1`, and the guard
was restored before commit.

All 87 `CredentialIdentityStoreManagerTests` passed after that correction. Further
hardening could independently compare the current request host with the resolved
entry before any identity-driven completion.

### KF-03 — A 32-byte passkey value could terminate AutoFill

Affected paths included:

- `KeeForge/Services/Security/PasskeyCrypto.swift`
- `AutoFillExtension/CredentialProviderCoordinator.swift`

KeeForge supports PKCS#8, SEC1, and raw 32-byte P-256 private keys. After DER parsing
failed, the fallback helper admitted buffers of at least 32 bytes and scanned for
the SEC1 marker with this range:

```swift
for i in 0..<(bytes.count - 33) {
    // scan for 04 20 followed by a 32-byte scalar
}
```

For an exact 32-byte buffer, the expression becomes `0..<(-1)`. Swift traps while
constructing that range, before the later raw-key fallback or ordinary error
handling can run.

The practical path required an unlocked database containing the passkey fields and
selection of the affected passkey through AutoFill. Swift's bounds enforcement made
this a memory-safe, repeatable denial of service rather than memory corruption or
secret disclosure.

The fix handles the supported exact-32-byte raw form first and rejects values below
the 34-byte DER-scan minimum. CryptoKit still validates the returned scalar. Tests
cover valid raw, PKCS#8, and SEC1 keys plus invalid 32- and 33-byte inputs on iOS and
macOS.

### KF-04 — Extreme timestamps could abort database saves

Affected paths included:

- `KeeForge/Models/KDBXParser.swift`
- `KeeForge/Models/KDBXXMLSerializer.swift`

KDBX 4 binary timestamps contain a signed 64-bit count of seconds since year 1.
The parser accepted the full range and converted it to Foundation `Date`, whose
time interval is a `Double`. Near the upper boundary, `Int64.max` rounds to exactly
`2^63`. The serializer later performed a trapping `Int64(Double)` conversion, so a
database could open successfully but abort the process whenever a save serialized
the retained timestamp.

The XML was still inside an authenticated KDBX payload. A useful trigger therefore
required someone able to author a valid shared/imported vault that the user could
unlock, followed by an action that saves. The result was an unsaveable database and
potential loss of pending edits, not memory corruption, code execution, or a KDBX
authentication bypass.

The fix makes timestamp serialization total: NaN maps deterministically to zero,
and values at or beyond the floating-point representations of `Int64.max` and
`Int64.min` saturate before conversion. Ordinary values retain their prior
truncation and byte encoding. Tests round-trip both signed extremes and separately
pin an ordinary timestamp byte-for-byte on iOS and macOS.

### KF-05 — Stored passwords began visible in the editor

Affected paths included:

- `KeeForge/ViewModels/EntryEditViewModel.swift`
- `KeeForge/Views/EntryEditView.swift`
- `KeeForge/Views/PasswordInputRow.swift`

The entry-detail view required device-owner authentication before revealing or
copying a stored password. Edit mode decrypted the value into form state—as editing
requires—but initialized `isPasswordVisible` to `true`, causing a selectable
`TextField` to render immediately. The platform's standard Copy action could also
bypass KeeForge's expiring/local-only clipboard helper.

This was an inconsistent local control, not an in-scope remote vulnerability.
Exploitation required physical access to a device whose KeeForge database was
already unlocked, exactly the scenario excluded by `SECURITY.md`. It was fixed as
defense in depth because neighboring screens promised a device-owner check for the
same stored value.

Edit mode now starts with a `SecureField`; revealing it calls
`BiometricService.authenticateDeviceOwner`. Create mode remains visible because
there is no pre-existing stored secret. Unit tests cover the mode-specific policy,
and the targeted UI test verifies the concealed-to-editable transition. The UI test
harness intentionally bypasses the real system authentication sheet, so on-device
prompt presentation remains a manual check.

Once an authorized user reveals the editable field, the platform selection menu can
still copy it directly. Eliminating that residual behavior would require a separate
non-selectable editing design and is not part of the unauthenticated exposure fixed
here.

### KF-06 — Dirty drafts deferred automatic locks without reauthentication

Affected paths included:

- `KeeForge/ViewModels/DatabaseViewModel.swift`
- `KeeForge/App/KeeForgeApp.swift`
- `KeeForge/App/RegularDatabaseWorkspaceView.swift`

Background and inactivity lock requests called `lockRequest()`. A clean database
locked immediately, but a dirty draft only created a pending confirmation while the
view model remained unlocked with its session key, entry tree, navigation state,
and draft intact. “Keep Editing” or ordinary alert dismissal cleared the request
and restarted the inactivity timer without authentication.

As with KF-05, the practical scenario required physical interaction with a device
whose OS session and KeeForge vault were already unlocked. It is therefore best
classified as lock-policy correctness and defense in depth, not as the original
medium-severity vulnerability. It still contradicted the user's configured
background/automatic-lock expectation.

The fix distinguishes manual confirmations from automatic pending requests. “Keep
Editing” on an automatic request invokes device-owner authentication; cancellation
or failure force-locks and discards the draft. Manual lock cancellation remains
immediate. Alert dismissal no longer clears the pending state, and the direct
cancel method is private.

This design preserves unsaved work rather than discarding it automatically. One
fallback remains explicit: when `canAuthenticateDeviceOwner` is false—including
the test-only launch mode—the implementation resumes without a prompt. That matches
the existing reveal/copy policy for devices with no configured owner-auth method,
but it means the fix is not an unconditional fail-closed lock. A future product
decision could instead force-lock and lose the draft when authentication is
unavailable.

Unit tests cover automatic/manual classification, background timeout behavior, and
manual draft preservation on iOS and macOS. The real Face ID/passcode resume flow
was not automated.

## Remediation Verification

The final fix was verified in increasing scope:

1. Focused iOS regressions for all six canonical issues passed together.
2. The relevant iOS owning classes passed for key-file processing, database
   creation, KDBX parsing/round trips, passkeys, entry editing, locking,
   `DatabaseViewModel`, credential identities, and the AutoFill coordinator.
3. The complete corrected `CredentialIdentityStoreManagerTests` class passed after
   the IPv4 compatibility issue found during validation was repaired.
4. The targeted `EntryEditSmokeUITests` password-edit flow passed.
5. Corresponding macOS owning classes passed, including the shared parser,
   cryptography, AutoFill, editor-policy, and lock-state tests.
6. After rebasing onto newer `main` changes that overlapped `DatabaseViewModel` and
   its tests, the complete `DatabaseViewModelTests` class passed again on both iOS
   and macOS.
7. Static diff checks passed, and the final commit contained only the implementation,
   tests, and user-facing changelog entries.

The original issue was shown not to reproduce through focused boundary tests:
malformed key files now throw and leave no created database, public-suffix inputs
produce tenant-correct identities, malformed passkey lengths throw, extreme
timestamps round-trip, existing passwords begin concealed, and automatic dirty-lock
requests are marked for authenticated resume.

Legitimate behavior was preserved by positive tests for password-only and valid
key-file databases, PKCS#8/SEC1/raw passkeys, ordinary timestamp bytes, ordinary/IP/
localhost domain handling, create-mode password editing, and manual preservation of
unsaved drafts.

## Limitations and Follow-up

- The original scan was static. Model-panel consensus is review evidence, not a
  substitute for runtime reproduction.
- No standalone exploit artifacts were created. The follow-up used safe unit and UI
  regressions rather than deliberately weak databases or crash fixtures.
- Apple's end-to-end matching behavior for a credential identity whose identifier is
  itself a public suffix remains untested on a physical device.
- The actual system device-owner prompt for dirty-draft resume and editor reveal is
  intentionally bypassed by XCUITest and should be checked manually on-device.
- The Public Suffix List is a bundled snapshot and should continue to receive package
  updates.
- A second host check in the AutoFill coordinator would reduce reliance on system
  identity metadata.
- The dirty-draft resume fallback when device-owner authentication is unavailable is
  an explicit policy tradeoff that could be tightened to force-lock.
- The complete UI suite and release KDBX compatibility gate were not run for this
  remediation; the focused unit, UI, and cross-platform owning suites were selected
  because they exercised every changed boundary.

## Conclusion

The audit was useful, but its raw headline overstated the number of independent
problems. Twelve reports became six code-level issues, and two of those were
defense-in-depth observations outside the repository's stated physical-access
scope. The consolidated view makes remediation priority much clearer.

The key-file derivation defect warranted immediate attention and is now closed at
the shared fail-closed boundary. The AutoFill domain issue was corrected with the
repository's existing public-suffix implementation while retaining uncertainty
about platform matching. The two low-severity traps now fail safely, and the UI/
lock changes make device-owner authentication more consistent without pretending
that already-unlocked physical access is a remote security boundary.

Future audits should continue to emphasize complete input-to-sink paths, explicit
policy boundaries, deduplication by root cause, and executable regressions over
finding counts or model-vote totals.
