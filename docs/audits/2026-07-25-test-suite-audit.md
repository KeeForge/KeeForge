# Test Suite Audit — 2026-07-25

Full audit of every test target in the repo: `KeeForgeTests` (compiled into both `KeeForgeTests` and `KeeForgeMacTests`), `KeeForgeUITests`, `KeeForgeMacUITests`, the KDBX compatibility artifact gate (`ci_scripts/run_kdbx_compatibility_gate.sh`), fixtures (`TestFixtures/`), and the CI wiring (`.github/workflows/`, Xcode Cloud, local release gate).

Method: five parallel read-only audit passes (unit tests models/crypto, unit tests services/viewmodels, UI tests, KDBX compatibility/data-safety architecture, CI/test-strategy), findings cross-verified against the code, then fixes applied in themed commits. This document records the full findings — including recommendations that were deliberately **not** implemented — so future sessions don't re-derive them.

## Overall assessment

The suite was in better shape than feared. Coverage is deep where the risk is highest (DatabaseViewModel, DatabaseListStore, CredentialProviderCoordinator, WebDAV client/provider, cipher primitives with spec vectors, DatabaseDraft edit semantics), the UI suite already follows a smoke-vs-scoped organization with an above-average XCUITest harness, and the KDBX compatibility layers each verify something the others cannot. The problems were: a handful of genuinely duplicated or worthless tests, silent drift between duplicated helpers, one structural double-execution in the compatibility pipeline, an external gate that never verified a protected value, and a few real coverage gaps (foreign-authored non-AES databases, KDBX4 tamper rejection, Keychain service, backup restore).

## 1. Unit tests — coverage and duplication

### Implemented in this audit

- **Deleted `VerifyKeyfileTests.swift`** — a leftover debugging script: brute-forced 6 candidate passwords against `demo-keyfile.kdbx`, `print()`-logged attempts, returned on first success without asserting content. The fixture pair is properly exercised with known credentials by the writer/round-trip suites.
- **Deleted `PasskeyDisplayTests.swift`** — all five tests duplicated `PasskeyTests.swift`'s `PasskeyCredentialTests` scenarios, and used hardcoded `"KPEX_PASSKEY_*"` literals instead of the `PasskeyCredential` constants (drift risk). Unique assertions (if any) folded into `PasskeyTests.swift`.
- **Extracted `CloudSyncCoordinatorTests`** out of `DatabaseViewModelTests.swift` into its own file — it tests `Cloud/CloudSyncCoordinator.swift` and was invisible to file-based discovery and `-only-testing:` slicing intuition.
- **Deduplicated the Dropbox scope-request test** (was asserted identically in `DropboxCloudProviderTests` and the mac-only `CloudProviderDesktopAuthTests`; the cross-platform copy owns it now).
- **Deduplicated `fastArgon2idParameters()`** (was declared in both `AttachmentTests` and `KDBXCompatibilitySupport`).
- **Strengthened weak assertions**: `test_setGroupSearchingEnabled_unknownGroup_throws` (now checks the specific `DraftError`), `testAllEntriesIncludesNestedGroupEntries`, `testKP2AURLFieldsExcludedFromCustomFields` (name/body mismatch), `testArgon2HighParallelismAccepted` (now asserts the positive outcome), `testInspectRejectsNonKDBXData` (now checks which error).
- **Shared KDBX tree assertions**: `KDBXRoundTripTests` and `KDBXWriterTests` carried byte-identical copies of the `Fixture` struct and the `assertGroupsEqual`/`assertEntriesEqual`/`normalizedOpaqueXML`/`assertTOTPConfigsEqual` helpers — and the copies had **silently drifted**: the writer's versions lacked `searchingEnabled`, `expires`, and `expiryTime` checks, so a regression in those fields surviving a real binary save was invisible. Now one shared helper (`KDBXTreeAssertions.swift`) with the strongest union of assertions; no production regression surfaced when the restored checks ran. A third near-copy in `DatabaseDraftTests` was left in place deliberately: it compares raw `unknownXML` pre-re-encryption and checks `protectedStringKeys`, so unifying it needs a behavior toggle, not a mechanical merge.
- **New format-safety tests**: KDBX4 tamper rejection (bit-flip inside an HMAC block, corrupted header HMAC, truncated payload — previously only the KDBX3 analog existed), KDBX4 wrong-password and wrong-key-file rejection, RFC 6238 SHA-256/SHA-512 TOTP vectors (only SHA-1 was verified before), `KeeOTPSource.rewriting(...)` (nontrivial query rewrite feeding TOTP edits; had zero references), `EncryptedValue` Data-overload round-trip, `LocalDatabaseSaver` backup-restore (backups were written and pruned but never re-opened), `DatabaseDraft` byte-size history trimming and legacy `otpURL` preserve/invalidate, `PasskeyCrypto.extractP256RawKey` SEC1 fallback (the KeePassXC-interop path its doc comment promises; previously dead in the suite because every test PEM took the PKCS#8 fast path).
- **New service/viewmodel tests**: `KeychainService` (composite-key store/retrieve/delete — the most security-sensitive previously-untested file), `DatabaseCreationViewModel` (export/cloud-create/`clearSecrets`), expanded `EntryEditViewModelTests` (`canSave`, custom fields, `base32Encode`/`canonicalBase32Secret` round-trip). Shared `CredentialProviderPresenting` spy extracted (was two hand-rolled copies). `DatabaseListViewModelTests` no longer re-litigates the store-owned targeted-removal invariant (owned by `DatabaseListStoreTests`).

### Documented, deliberately not implemented

- **Three independent hand-rolled ChaCha20 implementations** exist: `KDBXCrypto.chacha20XOR` (has RFC 8439 vectors), `KDBXParser.makeChaCha20Block` (inner-stream decode), and `KDBXXMLSerializer.makeChaCha20Block` (protected-field re-encryption). Consolidating them is production work on stable-core files and was left for an explicit decision. Mitigations that exist today: the parser's implementation is cross-validated de facto (it decodes protected values from pykeepass-authored fixtures), and this audit added external protected-value verification to the release gate, which cross-validates the serializer's implementation against KeePassXC. A future consolidation to a single implementation is still recommended.
- `DatabaseViewModelTests` re-tests some pure `Group`/`DatabaseDraft` logic through ViewModel passthroughs (duplicating `ModelLogicTests`/`DatabaseDraftTests`). Acceptable defense-in-depth; trim opportunistically.
- ~15 call sites use the "sleep 100–150 ms, then assert nothing happened" pattern for negative assertions (`CredentialIdentityStoreManagerTests`, `DatabaseListStoreTests`, `CredentialProviderCoordinatorTests`). Inverted `XCTNSPredicateExpectation`s would be sounder, but converting them is mechanical churn with its own flake risk; convert opportunistically when touching those files.
- `DropboxCloudProviderTests` is minimal for a 778-line provider; the pure error-mapping/sort/conversion helpers are testable but wrap SwiftyDropbox SDK types that are awkward to construct. Backfill when Dropbox code next changes.
- `KeeForgeApp.handleOpenURL` (file-open/OAuth-redirect dispatch) has no direct tests; testing it requires extracting it from the `App` struct. Recommended as part of any future App-layer refactor.
- `ScreenProtectionService.showShield/hideShield` and screen-capture monitoring are untested (require real `UIWindowScene`); the pure decision helpers are tested. Extract more decision logic if this area changes.
- Dead production code flagged: `KDBXParser.ParseError.headerFieldMissing`/`.innerHeaderInvalid` appear unreachable; `Group.allEntries(excludingGroupID:)` non-AutoFill variant has no references.
- Diagnostics quality (behavior pinned by tests, not changed): a corrupted KDBX4 outer header is reported as `invalidSignature` ("Not a valid KDBX file") because the header SHA-256 is checked before the header HMAC — correct rejection, misleading message; and KDBX4 wrong-password / wrong-key-file / corrupted-file all surface as the same `hmacMismatch`, with a blunter message than the KDBX3 wrong-password path. Improving these messages is a small, worthwhile product change.

## 2. UI tests — organization and practices

The suite already matches the intended shape: release-smoke classes per journey, scoped edge classes, opt-in harness classes, one strong base class (`KeeForgeUITestCase`), fixture seeding via launch environment, and a maintained accessibility-identifier catalog. Verified: every `UI_TEST_*` env var has a live app-side consumer.

### Implemented in this audit

- **`AppStoreScreenshots` is now opt-in** (`TEST_RUNNER_APPSTORE_SCREENSHOTS=1`, env-gated like `MacScreenshotAuditUITests` already was). It previously executed on every full `KeeForgeUITests` run — including both RC release gates — spending ~15+ s of hard `sleep()` plus a full walkthrough duplicating existing smoke assertions. Empirical footnote recorded in the READMEs: the variable must be a real env var on the `xcodebuild` process; a trailing `KEY=value` argument is silently ignored and the class skips as if unset.
- **Backoff/lockout coverage deduplicated**: `LockUnlockUITests.testFailedThenSuccessfulUnlock` repeated 4 wrong Argon2 unlocks, nearly duplicating `BackoffUITests` (5 wrong unlocks). `BackoffUITests` now owns the repeated-failure/lockout behavior; `LockUnlockUITests` keeps manual-lock and single-wrong-password. The hard `sleep(4)` in `testManualLockBehavior` was replaced with a poll.
- **Shared details-sheet helpers**: `openDatabaseDetails`/`closeDatabaseDetails`/`setSwitch` were byte-for-byte duplicated between `DatabaseListUITests` and `AutoFillStoreUITests`; promoted to `KeeForgeUITestCase`.
- **New journey coverage**: `TOTPSmokeUITests` (a 6-digit code renders on the entry detail and `entry.copy.totp` is hittable — logic was unit-tested but the UI wiring had no test; new `entry.totp.code` identifier) and a scoped Settings → Security test asserting the lock-on-background toggle renders and persists. Audit note: iOS has no screen-protection toggle — `blockScreenCapture` is macOS-only UI per its own doc comment; iOS shields via `UIScreen.isCaptured` with no user-facing switch.

### Documented, deliberately not implemented

- `AutoFillStoreUITests` (861 lines) is *not* a dedup target: five justified scenarios against the real `ASCredentialIdentityStore`, self-skipping off-harness; the length is doc comments and store/relaunch choreography.
- The two `DatabaseCreation*UITests` layout variants repeat the full create→reopen path per width; justified by layout-specific fragility, but the regular-width variant could shrink to layout-specific deltas if maintenance cost grows.
- Remaining known gaps, judged acceptable: attach-a-new-file flow (viewing is covered; creation is document-picker-heavy and flake-prone), OneDrive connect/browse (no mock provider exists; real MSAL OAuth is not automatable), Face ID unlock, passkey ceremonies, timer-based auto-lock (all system-UI or timing bound — correctly covered at unit level instead).
- A `.xctestplan` with Smoke/Edge configurations would make the tiering enforceable rather than documentation-only; worth doing if a smoke-only CI lane is ever wanted.

## 3. KDBX data-safety and ecosystem compatibility

Layer map (each layer catches something only it can): XML round-trip (serializer determinism, opaque-XML positioning) → container round-trip (header/HMAC/cipher/KDF) → edit-semantics matrix (`KDBXCompatibilityTests` — proves an edit changes exactly the intended fields) → external gate (`keepassxc-cli` — proves output is readable by the ecosystem, not just by KeeForge) → save-path safety (SHA-512 precondition, backups, atomic replace).

### Implemented in this audit

- **Artifact emission merged into the matrix run.** `KDBXCompatibilityArtifactTests` re-executed every compatibility scenario (~19 extra Argon2d-64 MiB load/write cycles on every CI run of the full unit suite) solely to emit files that only the local gate reads. Emission now happens inside the matrix tests themselves (per-test manifest fragments; the gate script merges them and fails on missing fragments, conflicting duplicates, or declared-but-unemitted artifact IDs), and the duplicate class is retired. Net effect: scenario executions per suite run dropped from ~40 to 24 with the artifact set unchanged at 19, and the gate now runs the fully-asserted matrix before the external check — less CI time *and* a stronger gate.
- **The gate now verifies protected values.** Previously `keepassxc-cli` checked titles, group paths, and attachment hashes — never a password KeeForge encrypted. A wrong-but-self-consistent protected-stream implementation would have passed. The manifest now carries expected passwords and the gate checks them via `keepassxc-cli show -s`: 18 password checks across 10 artifacts, deliberately pairing a KeeForge-written password with a fixture-authored one per artifact (the latter proves foreign-inner-stream → KeeForge-inner-stream re-encryption). Verified end-to-end against keepassxc-cli 2.7.12, including exercised failure paths (tampered password, deleted fragment, conflicting duplicate all fail the gate).
- **Fail-closed expectations**: `expectedAttachments(forScenarioID:)` returned `[]` for unknown IDs, so renaming a scenario silently dropped external attachment verification. Now fails closed.
- **Single smoke-fixture list**: the matrix tests and the artifact plans each hard-coded their own fixture list with nothing keeping them in sync.
- **Whole-binary-pool digest** added to `CompatibilitySnapshot`: orphaned pool entries, reordering, or a flipped protection flag on an unreferenced binary previously passed every matrix assertion (only *referenced* binaries were hashed).
- **Foreign-authored non-AES fixtures**: every prior fixture was AES-256 outer cipher authored by pykeepass or KeeForge itself, so ChaCha20/Twofish reads were only ever tested against KeeForge's own output (self-consistency, not compatibility). Added pykeepass-authored ChaCha20 and Twofish KDBX4 fixtures (`TestFixtures/compatibility/foreign-*.kdbx`, cipher UUIDs verified by independent raw-header parse; regenerable via the checked-in generator script) wired into the parser tests and the compatibility smoke matrix — bringing the gate to 21 artifacts and 22 protected-password checks, with KeePassXC reading back KeeForge-rewritten copies of both foreign files.

### Documented, deliberately not implemented

- **Unknown inner-header field preservation (production change).** `KDBXParser` skips unrecognized inner-header field IDs and `KDBXWriter` re-emits only the fields it knows, so any future KDBX inner-header extension would be dropped on first save. The outer header has both preservation and a test; the inner header has neither. This is real format work on stable-core files — do it as an explicit, focused change with matrix coverage, not as an audit side effect.
- **Fixture copies stay.** `compatibility/` contains byte-identical copies of several root fixtures; `TestFixtures/README.md` documents this as intentional (gate coverage can be retargeted without renaming unit-test fixtures). Kept as-is; be aware the copies may legitimately diverge later.
- Remaining fixture-matrix holes, in priority order: a KeePass2.x-authored fixture (reference implementation; nothing in the tree was written by it), an uncompressed (`compressionFlags == 0`) fixture, KDBX 4.1-only schema elements (`PreviousParentGroup`, group `Tags`, `QualityCheck`), a large (5–50 MB) database for a memory/perf floor, and hostile-input probes (entity expansion, deep group nesting vs the recursive walkers, duplicate UUIDs, oversized pool).
- A freshly-created database (`DatabaseCreationDefaults` production KDF params) never reaches the external gate; the synthetics use weakened Argon2 parameters. Worth routing one real-parameter creation artifact through the gate if gate runtime stays acceptable.
- The gate script's three-layer fallback for `xcresulttool` attachment-name resolution is fragile against Xcode changes; if it ever silently falls back, a stale export could mask a failure. Consider asserting the primary path.

## 4. Test-execution strategy (CI)

Current shape, confirmed accurate: PR → unit tests on latest iOS (aggregate-verdict pattern); `rc/*` tag → full unit+UI on Xcode Cloud (latest iPhone + SE, latest OS) and on GitHub Actions (iPhone SE, iOS 18 = min OS); release → local `keepassxc-cli` gate on the Mac mini; `ci.yml` manual-dispatch only (includes the only Mac unit-test run); `KeeForgeMacUITests` local-only. Verified via the GitHub API: `main` is protected by an active ruleset requiring the `unit-tests` and `DCO` status checks plus linear history and no force-pushes; the maintainer's direct pushes ride the owner bypass, which is why the PR gate never fires on them.

### Implemented in this audit

- **iPad lane for the two regular-width UI classes** in `ios18-rc-tests.yml`. `DatabaseCreationRegularWidthUITests` and `RegularWidthWorkspaceUITests` `XCTSkip` below 700 pt width, and every CI destination was compact-width — a permanent 100 % skip rate that whole-bundle "passing" reports made invisible.

### Considered and declined

- **Per-push unit tests on `main`** — declined by the maintainer: many commits are pushed directly to main daily, so a per-push gate would mostly re-test near-identical states and burn Actions minutes. The rc-tag gates remain the backstop; the risk accepted is that a unit regression can sit on main between RCs.
- Weekly scheduled UI run — same cost/benefit call as above; revisit if inter-release gaps grow.
- Automating the local gate via self-hosted runner — the manual pre-release step is deliberate (needs `keepassxc-cli`, absent on hosted CI); the release skill encodes it.
- Folding `KeeForgeMacUITests` into manual `ci.yml` — GitHub's macOS runners often lack the unlocked interactive session XCUITest needs; revisit when the mac app comes off hold.

## Commit map

Applied as themed commits on main (this audit): unit-test hygiene → shared tree assertions → compatibility restructure + gate hardening → format-safety tests → service/VM tests → foreign cipher fixtures → UI test improvements → CI iPad lane + this report.
