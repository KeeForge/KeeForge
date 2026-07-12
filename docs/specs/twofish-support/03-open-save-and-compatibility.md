# Slice 03: Open, Save, and Compatibility

> Parent: [`epic.md`](./epic.md) · Depends on: 01, 02

## Goal

Prove that Twofish KDBX 4.x remains valid and cipher-preserving through every supported edit/save route, AutoFill, lock lifecycle, rich data shapes, and KeePassXC interoperability.

## Scope

**In:**

- Add Twofish to the authoritative KDBX compatibility matrix and artifact gate.
- Cover local atomic save/backup/cache, conflict-copy, cloud upload/conflict, and AutoFill unlock/save/pending-upload behavior.
- Exercise every supported edit against a synthetic rich Twofish KDBX 4 fixture, including a deterministic attachment larger than 1 MiB.
- Verify lock/session behavior, off-main execution, and regression coverage for AES/ChaCha20.
- Make only minimal production-flow changes if a test reveals an assumption that incorrectly rewrites/rejects a supported Twofish KDBX 4 header.

**Out:**

- New edit semantics, cloud providers, AutoFill UI, creation options, telemetry, or migrations.
- KDBX 3.1 write/save integration beyond proving every path rejects it.
- Streaming or memory-architecture changes.

## Compatibility matrix

Extend `KDBXCompatibilitySupport` with these roles:

- **External smoke — KDBX 4.0 Argon2d:** load the sanitized reported-profile fixture, make the standard smoke edit, write/reparse, and emit a KeePassXC artifact.
- **External smoke — KDBX 4.1 Argon2id + key file:** load the no-compression/protected-field/attachment/unknown-header fixture, make the smoke edit, write/reparse, and emit the database plus key file.
- **Read-only smoke — KDBX 3.1:** parse and snapshot the Twofish legacy fixture, assert read-only mode, and assert writer/save rejection. Do not emit a modified artifact.
- **Synthetic rich Twofish:** generate KDBX 4 through the production fresh-header test helper with the Twofish UUID, a recycle bin, protected values, history, custom/unknown XML, public custom data, attachments, and a deterministic binary attachment greater than 1 MiB. Run every scenario returned by `fullEditScenarios()`.
- **Regression smoke:** retain the existing AES rich/no-recycle, ChaCha20, password+key-file, KDBX 4.1 unknown-header, unknown-XML, and attachment scenarios.

For every writable Twofish scenario, compare before/after semantic snapshots and reparse the encrypted result. In addition to the scenario's intended change, assert preservation of:

- KDBX major/minor version and Twofish UUID.
- KDF UUID, salt shape, iteration/memory/parallelism/version parameters.
- Compression flag and actual compressed/uncompressed payload behavior.
- Inner protected-field stream ID and valid protected-value round trip.
- Unknown outer fields, metadata/custom data, unknown XML, history, recycle-bin semantics, groups, entries, tags, icons, and deleted objects.
- Attachment names, refs, pool bytes, protection flag, SHA-256, dedup behavior, and the greater-than-1-MiB binary length.

Fresh randomness means whole-file bytes are not expected to match the source; compare structure/content and assert the new master seed/IV differ.

## Save-route requirements

### Local and conflict copy

- Normal local save keeps the existing SHA-512 conflict preflight, creates the timestamped backup from original encrypted bytes, writes via the existing coordinated/atomic path, and refreshes the shared AutoFill cache with the exact newly written Twofish bytes.
- A detected source conflict does not overwrite either version. `saveAsConflictCopy` produces a parseable KDBX 4 Twofish copy with the staged edit and preserved header settings.
- Read-only KDBX 3.1 never enters writer/local-saver code, including conflict-copy entry points.

### Cloud

- Cloud save uploads bytes that reparse as Twofish with the staged edit and preserved header settings.
- Provider revision/precondition conflict behavior remains unchanged: no silent retry or AES rewrite, and the local draft remains recoverable.
- Download/cache/open behavior is cipher-agnostic; offline cached Twofish files follow the same policy as AES.

### AutoFill

- The extension can unlock both KDBX 4 Twofish fixtures using the shared parser, including the password+key-file case.
- Saving a generated credential through `AutoFillSaveCoordinator` writes a Twofish cached database; the main app can reopen it and find the new entry.
- For cloud-backed databases, the pending-upload record references the exact Twofish bytes and metadata produced by the extension. Draining/upload conflict semantics remain unchanged.
- Extension code remains app-extension safe and does not gain a second cipher implementation.

### Lock and execution lifecycle

- Parsing/writing and Ferguson initialization never execute on the main actor in app or extension flows.
- Locking clears the existing session key/draft access exactly as before. A lock during an in-flight save follows current snapshot semantics, exposes no decrypted data, and cannot reuse cleared session state for a later save.
- Reopening after lock derives fresh keys and can read the saved Twofish file.
- Whole-`Data` handling of the synthetic greater-than-1-MiB attachment completes within the existing XCTest timeout without crash, truncation, or extension-memory termination. Record `XCTClockMetric` and `XCTMemoryMetric` for parse + one edit + save so future regressions have a checked-in baseline; do not introduce a flaky device-wide absolute timing assertion.

## Affected areas

- Modified: `KDBXCompatibilitySupport.swift`, compatibility unit/artifact tests, local/cloud/AutoFill/database-view-model tests, and the unit-test/fixture README maps.
- Conditional only if tests fail: local/cloud saver, `DatabaseViewModel`, or `AutoFillSaveCoordinator` code that contains an AES/ChaCha-only assumption. Do not add cipher-specific branches to storage/provider code; it should continue to pass encrypted bytes from the shared writer.
- Modified: compatibility gate manifest expectations only as needed to include Twofish artifacts and the large attachment hash.

## KeeForge bits

- **Targets:** compatibility and saver/view-model tests belong to `KeeForgeTests`. `LocalDatabaseSaver` and `AutoFillSaveCoordinator` are shared with `KeeForgeAutoFill`; `CloudDatabaseSaver` and `DatabaseViewModel` are main-app only. Any production change preserves those existing memberships.
- **project.yml:** no changes expected beyond Slice 02's fixture resources. If an additional bundled fixture becomes necessary, add it only to `KeeForgeTests` resources and run `xcodegen generate`; generated rich data is preferred.
- **Accessibility identifiers:** N/A — no view-layer work and no UI tests.

## Testing

### Unit: compatibility

- `KDBXCompatibilityTests.swift` runs all edits on synthetic rich Twofish; external KDBX 4 smoke; KDBX 3.1 read-only rejection; header/KDF/compression/stream/unknown XML and greater-than-1-MiB attachment preservation; AES/ChaCha regression.
- `KDBXCompatibilityArtifactTests.swift` emits both external KDBX 4 Twofish smoke outputs plus all synthetic rich Twofish edit outputs. The manifest includes required key files, expected search/group terms, and expected attachment names/hashes.

Run:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/KDBXCompatibilityTests \
  -only-testing:KeeForgeTests/KDBXCompatibilityArtifactTests -quiet
```

### Unit: save and lifecycle

- `LocalDatabaseSaverTests`: Twofish normal save, original-byte backup, atomic replacement, exact shared-cache refresh, conflict refusal, conflict-copy preservation, and KDBX 3.1 rejection.
- `CloudDatabaseSaverTests`: uploaded Twofish bytes reparse with edit; provider conflict does not rewrite cipher or lose draft.
- `CredentialProviderSaveTests`: extension unlock and generated-entry save for Twofish; password+key-file; exact pending-upload bytes; main-app reparse.
- `PendingUploadQueueTests`: queued Twofish encrypted bytes survive persistence/reload without mutation and keep existing file-protection behavior.
- `DatabaseViewModelTests`: local/cloud/conflict-copy orchestration, read-only KDBX 3.1, lock during/after save, reopen, and off-main assertions.
- `TwofishTests`: repeat the 100-operation concurrency/once-initialization case while app-level tests execute in randomized order.

Run:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/LocalDatabaseSaverTests \
  -only-testing:KeeForgeTests/CloudDatabaseSaverTests \
  -only-testing:KeeForgeTests/CredentialProviderSaveTests \
  -only-testing:KeeForgeTests/PendingUploadQueueTests \
  -only-testing:KeeForgeTests/DatabaseViewModelTests \
  -only-testing:KeeForgeTests/TwofishTests -quiet
```

### External compatibility gate

```bash
ci_scripts/run_kdbx_compatibility_gate.sh
```

The gate passes only when `keepassxc-cli` opens every emitted Twofish artifact with its declared password/key file, finds the expected edited records/groups, and exports the expected large and regular attachments with matching SHA-256 hashes.

### Manual

- On a device or simulator, open/edit/save each KDBX 4 fixture locally, lock/reopen it, and confirm KeePassXC still reports Twofish and the original KDF/compression settings.
- Repeat one cloud save and one forced revision conflict; verify the remote or conflict copy opens in KeePassXC and no source is silently overwritten.
- Use AutoFill to unlock the password+key-file fixture and save a generated credential; reopen the shared/cloud cached copy in the main app.
- Confirm the KDBX 3.1 fixture stays read-only in both app and AutoFill and no save/pending-upload artifact is created.

## Exit criteria

- [ ] All external and synthetic Twofish compatibility scenarios pass without unrelated semantic changes.
- [ ] The greater-than-1-MiB attachment survives app/AutoFill parse and save with exact length/hash; performance metrics are recorded.
- [ ] Local backup/atomic/cache and conflict-copy behavior preserve valid Twofish KDBX 4 bytes.
- [ ] Cloud upload/conflict and AutoFill/pending-upload behavior preserve valid Twofish KDBX 4 bytes.
- [ ] Lock lifecycle clears session access, exposes no secrets, and supports a clean reopen.
- [ ] KDBX 3.1 remains read-only through every entry point.
- [ ] AES, ChaCha20, database creation, and existing compatibility artifacts remain green.
- [ ] `ci_scripts/run_kdbx_compatibility_gate.sh` passes with all Twofish search/group/attachment checks.
- [ ] Main app and AutoFill compile under strict concurrency; no force unwraps or secret logs were added.
- [ ] `KeeForgeTests/README.md` and `TestFixtures/README.md` describe the new tests/fixtures.
- [ ] Replace Slice 02's CHANGELOG line with the final entry below under `## Unreleased`.

## CHANGELOG entry

Replace the Slice 02 entry with the final single line:

`- Added Twofish database support across opening, editing, local and cloud saving, and AutoFill, with read-only support for KDBX 3.1.`
