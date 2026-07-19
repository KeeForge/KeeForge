# Deferred Tests: Selectable AutoFill Per Database

> **Why this file exists.** The epic was implemented in a Linux environment with no Apple
> toolchain, so no tests could be written or run alongside the code. This document is the
> pick-up list for a follow-up session on a Mac: every test each slice requires, written
> against the *actual* implementation (real type names, real seams), plus the toolchain
> steps that could not run on Linux.
>
> **How to pick this up.** Work slice by slice, smallest test slice first, using the exact
> `-only-testing:` commands given. When a section's tests are green, check its box in the
> checklist below.

## Toolchain follow-ups (run once, before/while writing tests)

- [ ] `xcodegen generate` — only needed if any new source/test files are added while writing
      the tests below (no new source files were added by the implementation itself).
- [ ] `swift scripts/normalize-xcstrings.swift` — the implementation edited
      `.xcstrings` catalogs as plain JSON; Linux cannot reproduce Xcode's
      `localizedStandardCompare` key order, so the catalogs must be normalized on a Mac and
      the diff re-committed. Then run `-only-testing:KeeForgeTests/LocalizationTests`.
- [ ] Full build of all targets (`KeeForge`, `KeeForgeAutoFill`, `KeeForgeMacAutoFill`) —
      the implementation was written without a compiler; fix any first-build breakage before
      starting on tests.
- [ ] `-only-testing:KeeForgeTests/AppGroupGuardrailTests` — the registry gained a plain
      bool field; guardrail must stay green.

## Slice checklist

- [ ] Slice 01 — AutoFill-enabled flag and publication gating
- [ ] Slice 02 — Database-tagged credential identities
- [ ] Slice 03 — Extension identity-to-database resolution
- [ ] Slice 04 — Multi-database aggregation and targeted removal
- [ ] Slice 05 — Settings UI and Clear AutoFill Entries
- [ ] Slice 06 — Extension database switcher
- [ ] Manual test pass (aggregated from the slice sections; device + mac extension)

---

## Slice 01: AutoFill-enabled flag and publication gating

### Implementation summary (what the tests pin down)

- `DatabaseReference.autoFillEnabled: Bool = true` — hand-written `Codable`: `CodingKeys.autoFillEnabled`,
  `decodeIfPresent ?? true` in `init(from:)`, unconditional `encode` in `encode(to:)` (same pattern as `isReadOnly`).
- `DatabaseListStore.setAutoFillEnabled(_:for:)` — **the single owner of disable consequences** (mirrors
  `remove(id:)`): no-ops for unknown ids and unchanged values; when the *active* database (resolved via
  `activeAutoFillDatabase`, so a legacy-fallback-active database counts) is disabled, it reassigns the pointer via
  private `nextActiveAutoFillDatabaseID(excluding:)` — most recently opened enabled database with non-nil
  `lastOpenedAt`, else `nil` — and then calls `CredentialIdentityStoreManager.clearStore()`.
- `DatabaseListStore.activeAutoFillDatabaseID` **setter** refuses non-nil ids whose persisted reference has
  `autoFillEnabled == false`; ids unknown to the persisted registry pass through (pre-first-save references);
  `nil` always clears. The gate reads via private `decodeStoredDatabases()` (no bootstrap/migration re-entry).
- `DatabaseListStore.activeAutoFillDatabase` getter skips a disabled pointed-to reference and falls through to
  `fallbackAutoFillDatabase(in:)`, which now requires `legacyKeychainFilename != nil && autoFillEnabled`.
- `DatabaseListStore.saveDatabases` sweep now clears the pointer when it references a *missing or disabled*
  reference (previously missing only) — this catches flag flips made through the generic `update(_:)` bypass.
- `DatabaseListStore.markDatabaseOpened(id:)` always updates `lastOpenedAt` but writes the pointer only when the
  reference is enabled. New accessor: `DatabaseListStore.autoFillEnabledDatabases`.
- `DatabaseViewModel.populateCredentialStoreIfNeeded(root:)` re-reads the reference from
  `DatabaseListStore.databases` (falling back to the in-memory `databaseReference` when not persisted) and, when
  disabled, skips **both** the pointer write and `CredentialIdentityStoreManager.populate` — the previous
  database's identities stay untouched.
- `AutoFillSaveCoordinator.saveNewEntry` wraps its pointer write + `environment.populateCredentialStore` call in
  `if reference.autoFillEnabled` (save itself still succeeds).
- `DatabaseListViewModel.setAutoFillEnabled(_:for:)` delegates to `DatabaseListStore.setAutoFillEnabled` then
  `reload()` (deliberately *not* the private generic `update` helper, which would bypass the consequences).

### Seams to use

- `CredentialIdentityStoreManager.populateObserver` / `clearObserver` (`#if DEBUG`, `@MainActor`). They fire via
  `Task { @MainActor in … }`, so positive assertions need `expectation` + `await fulfillment(of:timeout: 1)`;
  negative assertions use the existing pattern of an observer that `XCTFail`s plus
  `try? await Task.sleep(for: .milliseconds(100))` (see `DatabaseListStoreTests.testRemoveDoesNotClearCredentialStoreWhenRemovingInactiveDatabase`).
  Reset both observers to `nil` in `setUp`/`tearDown`.
  **Signature note (slice 02):** `populateObserver` is now `((UUID, [KPEntry]) -> Void)?` — the first argument is
  the owning `DatabaseReference.id` — so every closure in this section takes `(databaseID, entries)` (use
  `{ _, entries in … }` where the id is irrelevant, or additionally assert it equals the reference under test).
  `clearObserver` is unchanged.
- `AutoFillSaveCoordinator.Environment` with the existing private `SaveRecorder` +
  `makeEnvironment(recorder:)` helpers in `CredentialProviderSaveTests` (its `populateCredentialStore` closure is
  the populate seam; no real identity store is touched). **Signature note (slice 02):** the closure is now
  `@Sendable (UUID, [KPEntry]) -> Void` — adapt to `{ _, entries in … }` / `{ _, _ in }`.
- `DatabaseListStore.clearAll()` in `setUp`/`tearDown` (all four files already do this), plus
  `CloudAccountStore.clearAll()` / `SharedVaultStore.clearBookmark()` where the file already does.
- `SettingsService.quickAutoFillEnabled` defaults to true; `DatabaseViewModel` populate tests rely on that — do
  not run them with the shared-defaults key `KeeForge.quickAutoFillEnabled` left false by another test.
- Reference builders: `TestDatabaseSupport.makeReference(for:)`, `makeTemporaryFileURL(name:)`, and the private
  `makeLocalReference`/`makeCloudReference` helpers in `CredentialProviderSaveTests` (extend them with an
  `autoFillEnabled: Bool = true` parameter).
- To flip the flag in tests, prefer `DatabaseListStore.setAutoFillEnabled(_:for:)`; use plain
  `DatabaseListStore.update(_:)` only in the sweep test that deliberately exercises the bypass path.

### `KeeForgeTests/DatabaseReferenceTests.swift`

- `testDecodeLegacyJSONWithoutNewFieldsSetsDefaults` *(extend existing)* — add
  `XCTAssertTrue(decoded.autoFillEnabled)`: pre-feature JSON (the file-private `LegacyDatabaseReferencePayload`
  has no `autoFillEnabled` key) decodes as enabled — the migration guarantee.
- `testEncodeDecodeWithNewFieldsRoundTrips` *(extend existing)* — set `autoFillEnabled: false` on the fixture;
  the existing `XCTAssertEqual(decoded, reference)` (synthesized `Equatable` now includes the field) proves the
  non-default value round-trips both ways.
- `testEncodeAlwaysEmitsAutoFillEnabledKey` *(new)* — encode a default reference, decode the JSON as
  `[String: Any]`/`JSONSerialization`, assert the `autoFillEnabled` key is present and `true` (pins the plain
  `encode`, not `encodeIfPresent`, so pre-feature builds reading a new registry see an explicit value).

### `KeeForgeTests/DatabaseReferenceMigrationTests.swift`

- `testMigrationFromSharedVaultStoreProducesAutoFillEnabledReference` *(new)* — after
  `SharedVaultStore.saveBookmark(for:)` triggers legacy migration (same setup as
  `testMigrationFromSharedVaultStoreCreatesSingleReferenceAndCopiesLegacyCache`), the migrated reference has
  `autoFillEnabled == true` and `DatabaseListStore.activeAutoFillDatabase?.id` still resolves to it with the
  pointer cleared (the gated legacy fallback must accept it).

### `KeeForgeTests/DatabaseListStoreTests.swift`

- `testSetAutoFillEnabledPersistsAcrossReload` *(new)* — `setAutoFillEnabled(false, for:)` sticks on a fresh
  `DatabaseListStore.databases` read (the store re-decodes `database-list.json` on every access, so this is also
  the background→foreground reload guarantee), and `autoFillEnabledDatabases` excludes exactly that reference.
- `testActiveAutoFillDatabaseIDSetterRefusesDisabledDatabase` *(new)* — with an enabled db active and a second db
  disabled, assigning `activeAutoFillDatabaseID = disabled.id` leaves the previous id in place.
- `testActiveAutoFillDatabaseIDSetterAllowsUnknownID` *(new)* — an id not present in the registry is written
  unchanged (pins the pre-first-save pass-through that `CredentialProviderSaveTests` depends on).
- `testMarkDatabaseOpenedOnDisabledDatabaseKeepsPreviousActivePointer` *(new)* — `markDatabaseOpened` on a
  disabled db updates its `lastOpenedAt` but `activeAutoFillDatabaseID` stays at the previously active db.
- `testDisablingActiveDatabaseClearsStoreAndReassignsPointer` *(new)* — two enabled dbs, both
  `markDatabaseOpened` (older date first); disable the active one via `setAutoFillEnabled(false, for:)`:
  `clearObserver` expectation fulfills and the pointer moves to the *other, most recently opened* enabled db.
- `testDisablingActiveDatabaseWithNoOtherOpenedEnabledDatabaseClearsPointer` *(new)* — same but the only other db
  has `lastOpenedAt == nil` (never opened): `clearObserver` fires and the pointer becomes `nil`.
- `testDisablingInactiveDatabaseLeavesStoreAndPointerUntouched` *(new)* — disabling a non-active db must not fire
  `clearObserver` (XCTFail observer + 100 ms sleep) and must not move the pointer.
- `testEnablingDisabledDatabaseDoesNotPopulateOrClaimPointer` *(new)* — `setAutoFillEnabled(true, for:)` persists
  the flag but touches neither observer nor pointer (publication is lazy, on next unlock).
- `testFallbackAutoFillDatabaseSkipsDisabledLegacyDatabase` *(new)* — a reference with
  `legacyKeychainFilename != nil` but `autoFillEnabled == false`, pointer `nil`: `activeAutoFillDatabase` is
  `nil` (the legacy fallback never returns a disabled database).
- `testSaveSweepClearsPointerWhenFlagFlippedViaGenericUpdate` *(new)* — flip `autoFillEnabled` to false through
  plain `DatabaseListStore.update(_:)` on the active db: the `saveDatabases` sweep clears the pointer (documents
  the bypass path; note it deliberately does *not* clear the identity store — `setAutoFillEnabled` is the
  designated API).
- `testSetAutoFillEnabledOnLockedDatabaseNeedsNoUnlock` *(new, "locked database" edge)* — a reference added via
  `add(url:)` but never unlocked (no keychain composite key, no cached copy): `setAutoFillEnabled(false, for:)`
  persists and, when that db was active, still clears/reassigns — flag flips are registry-only.

### `KeeForgeTests/DatabaseViewModelTests.swift`

All via the `#if DEBUG` `CredentialIdentityStoreManager.populateObserver`/`clearObserver` seams and the existing
`makeViewModel(reference:)` + fixture-password helpers; the reference under test must be persisted with
`DatabaseListStore.update(reference)` first, because the view model's guard re-reads the registry.

- `testUnlockDisabledDatabaseDoesNotPopulateOrClaimActivePointer` *(new)* — persist reference with
  `autoFillEnabled == false`, make another enabled db the active pointer, unlock with the fixture password:
  state reaches `.unlocked`, `populateObserver` never fires (XCTFail observer + sleep), and
  `activeAutoFillDatabaseID` still holds the other db's id (both `markDatabaseOpened` and the populate path are
  gated).
- `testUnlockEnabledDatabasePopulatesAndSetsActivePointer` *(new)* — regression guard: enabled db unlock fires
  `populateObserver` with the fixture's entries and sets the pointer (today's behavior unchanged).
- `testSaveOnDisabledDatabaseDoesNotRepopulateStore` *(new)* — unlock an enabled db, flip it disabled via
  `DatabaseListStore.setAutoFillEnabled(false, for:)`, apply an entry edit and `save()`: `populateObserver` stays
  silent for the save's refresh call (the save-path caller of `populateCredentialStoreIfNeeded` is gated).
- `testPopulateCredentialStoreIfUnlockedRereadsFlagFromRegistry` *(new, background→foreground edge)* — unlock an
  enabled db (let the initial populate fire), disable it in the store *without* touching the view model, then
  call the public `populateCredentialStoreIfUnlocked()` (the foreground refresh entry point): no further
  `populateObserver` firing and no pointer write — proves the guard uses persisted state, not the view model's
  possibly-stale `databaseReference` copy.

### `KeeForgeTests/CredentialProviderSaveTests.swift`

- `test_saveNewEntry_autoFillDisabledReference_doesNotSetActiveOrPopulate` *(new)* — extend
  `makeLocalReference` with `autoFillEnabled: false`, run `saveNewEntry` with the `SaveRecorder` environment:
  the result is `.saved` with the entry present (saving is not blocked), but `recorder.populatedEntryTitles`
  is empty and `DatabaseListStore.activeAutoFillDatabaseID` is `nil`.
- `test_saveNewEntry_localSource_writesCacheAndCallsCompleteRequest_doesNotEnqueue` *(existing, keep green)* —
  still asserts the pointer is set for the default-enabled reference; this pins the unknown-id pass-through in
  the gated setter (the reference is never persisted to the registry in that test).

### Optional (beyond the spec's minimum)

- `DatabaseListViewModelTests.swift`: `testSetAutoFillEnabledDelegatesToStoreAndReloads` — after
  `viewModel.setAutoFillEnabled(false, for:)`, `viewModel.databases` reflects the flag (proves the helper routes
  through `DatabaseListStore.setAutoFillEnabled`, not the generic `update`).

### Run command

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseReferenceTests \
  -only-testing:KeeForgeTests/DatabaseReferenceMigrationTests \
  -only-testing:KeeForgeTests/DatabaseListStoreTests \
  -only-testing:KeeForgeTests/DatabaseViewModelTests \
  -only-testing:KeeForgeTests/CredentialProviderSaveTests -quiet
```

Also re-run `-only-testing:KeeForgeTests/AppGroupGuardrailTests` (registry gained a plain bool — must stay
green). Slice 01 edited **no** `.xcstrings` catalogs, so `swift scripts/normalize-xcstrings.swift` and
`LocalizationTests` are not required for this slice specifically (the toolchain section above still applies to
the epic overall).

---

## Slice 02: Database-tagged credential identities

### Implementation summary (what the tests pin down)

All new types live in `KeeForge/Services/AutoFill/CredentialIdentityStoreManager.swift` (no new files;
the file is already in the app target and both extension allow-lists — `project.yml` untouched).

- `CredentialRecordIdentifier` — the single owner of the record-identifier wire format.
  `CredentialRecordIdentifier(databaseID:entryID:).encoded` produces `"v2:<databaseUUID>:<entryUUID>"`
  (colon-joined, `UUID.uuidString` fields). `CredentialRecordIdentifier.parse(_:) -> ParseResult` classifies
  `.current(CredentialRecordIdentifier)` / `.legacy(entryID: UUID)` (bare entry UUID from pre-feature builds)
  / `.unrecognized` (everything else). `ParseResult.entryID` returns the entry UUID for both resolvable
  formats; `ParseResult.databaseID` is non-nil only for `.current`.
- `CredentialIdentityStoreProviding` (protocol, `Sendable`) — the store seam: `isEnabled()`,
  `replaceCredentialIdentities(_:)`, `saveCredentialIdentities(_:)`, `removeCredentialIdentities(_:)`,
  `removeAllCredentialIdentities()`, and `credentialIdentities() -> [any ASCredentialIdentity]?`
  (nil = enumeration unsupported, i.e. macOS 14.0–14.3; production gates on
  `#available(iOS 17.4, macOS 14.4, *)`). Production conformance: `SystemCredentialIdentityStore`
  wrapping `ASCredentialIdentityStore.shared`.
- `CredentialIdentityStoreManager` API (all ops resolve the store via the seam, gate on `isEnabled()`, and
  run in a fire-and-forget `Task`):
  - `populate(with: [KPEntry], for databaseID: UUID)` — filters expired entries, builds password + passkey
    (+ OTC on iOS 18/macOS 15) identities all tagged with the database id, then still **whole-store
    replaces** (`replaceCredentialIdentities`; `removeAllCredentialIdentities` when nothing is eligible).
    Aggregation is slice 04.
  - `removeIdentities(for: [KPEntry], in databaseID: UUID)` — rebuilds password + passkey identities
    byte-identical to publication (same tagged recordIdentifier) and removes them; the identical-rebuild
    contract exists because `removeCredentialIdentities(_:)` matching semantics are not formally documented.
  - `removeIdentities(forDatabase: UUID, includingLegacyIdentifiers: Bool = false)` — targeted removal:
    enumerate → filter by parsed database id (`.legacy` matches only when the flag is true, `.unrecognized`
    never) → `removeCredentialIdentities` on exactly that subset; skips removal entirely (with an error log)
    when enumeration returns nil. Needs no entry data.
  - `clearStore()` — unchanged wipe-everything primitive.
- Identity builders got the id parameter: `passwordIdentities(for:in:)`, `passkeyIdentity(for:in:)`,
  `oneTimeCodeIdentity(for:in:)`.
- `#if DEBUG` seams (all `@MainActor` statics, reset to nil in `setUp`/`tearDown`):
  `populateObserver: ((UUID, [KPEntry]) -> Void)?` (was `([KPEntry]) -> Void`),
  `clearObserver: (() -> Void)?` (unchanged), **new** `removeDatabaseObserver` (fires on
  `removeIdentities(forDatabase:)`; slice 04 extended it to `((UUID, Bool) -> Void)?` — the second
  argument is the `includingLegacyIdentifiers` flag, so write closures as `{ id, _ in … }` unless
  asserting the flag), and **new**
  `storeProviderOverride: (any CredentialIdentityStoreProviding)?` — when non-nil every operation uses it
  instead of the system store.
- `AutoFillSaveCoordinator.Environment.populateCredentialStore` is now `@Sendable (UUID, [KPEntry]) -> Void`;
  `.live` forwards to `populate(with:for:)`; `saveNewEntry` passes `reference.id`.
- `DatabaseViewModel.populateCredentialStoreIfNeeded` passes `databaseReference.id`.
- `CredentialProviderCoordinator` gained private `entryMatching(recordIdentifier:in:)` (parse → match on
  `ParseResult.entryID`, so current **and** legacy formats fill; `.unrecognized` returns nil). Used by all
  five former `$0.id.uuidString == recordIdentifier` sites: silent password path, interactive password path
  (`presentPasswordMatchesOrFinish`), `findEntry(byRecordIdentifier:)` (which passkey resolution uses), and
  both OTC paths (silent + `completeOTCRequestFromPending`).

### Required migrations of existing tests (compile fixes — do these first)

- `KeeForgeTests/CredentialIdentityStoreManagerTests.swift` — all `passwordIdentities(for:)` /
  `oneTimeCodeIdentity(for:)` calls gain `, in: someDatabaseID`; the two recordIdentifier assertions
  (`identities.first?.recordIdentifier == id.uuidString`, OTC equivalent) become
  `== CredentialRecordIdentifier(databaseID: someDatabaseID, entryID: id).encoded`.
- `KeeForgeTests/PasskeyTests.swift` — `passkeyIdentity(for:)` calls (3 sites) gain `, in:`; the
  `identity?.recordIdentifier == entry.id.uuidString` assertion becomes the tagged encoding.
- `KeeForgeTests/DatabaseViewModelTests.swift` — seven `populateObserver` closures become two-argument
  (`{ _, entries in … }` / `{ _, _ in }`): `testForegroundRefreshRepopulatesCredentialStoreWhenUnlocked`,
  `testApplyEntryEditRefreshesCredentialStoreFromDraft`,
  `testDeleteGroupRefreshesCredentialStoreAndMovesGroupToRecycleBin`,
  `testMoveToRecycleBinRefreshesCredentialStoreAndRemovesEntry`,
  `testPermanentDeleteFromRecycleBinRefreshesCredentialStore` (two closures),
  `testSaveRepopulatesCredentialStoreAfterSuccessfulSave`. While there, assert the received `UUID` equals
  the unlocked reference's id in at least one positive test.
- `KeeForgeTests/CredentialProviderSaveTests.swift` — inline environment `populateCredentialStore: { _ in }`
  → `{ _, _ in }`; the `SaveRecorder` environment closure `{ entries in … }` → `{ _, entries in … }` (or
  extend `SaveRecorder` with `populatedDatabaseIDs` and assert `reference.id` arrives).
- `KeeForgeTests/DatabaseListStoreTests.swift` — uses only `clearObserver` (unchanged signature): no compile
  change, but its slice 01 tests must stay green unmodified.

### Test infrastructure to build (in `KeeForgeTests`, shared by slices 02/04/05)

`FakeCredentialIdentityStore`: `final class FakeCredentialIdentityStore: CredentialIdentityStoreProviding,
@unchecked Sendable` guarding its state with an `NSLock` (prefer this over an `actor` — the protocol's
`[any ASCredentialIdentity]` parameters are non-Sendable AuthenticationServices types, and a lock-based
class avoids sending them across an actor boundary; add `@preconcurrency import AuthenticationServices`
at the top of the test file, mirroring the production file). Suggested surface:

- `var isEnabledValue = true`; `private(set) var stored: [any ASCredentialIdentity]`
- conformance methods mutate `stored` (`replace` = assign, `save` = append/overwrite, `remove` = drop
  matching `recordIdentifier`s, `removeAll` = empty) and record call names in `private(set) var calls: [String]`
- `var enumerationUnavailable = false` → `credentialIdentities()` returns nil (macOS 14.0–14.3 simulation)
- `var onMutation: (@Sendable () -> Void)?` invoked after every mutating call — the manager's operations are
  fire-and-forget `Task`s, so tests install the fake via
  `await MainActor.run { CredentialIdentityStoreManager.storeProviderOverride = fake }`, trigger the API,
  and `await fulfillment(of: [expectation], timeout: 1)` fulfilled from `onMutation`. Negative cases
  (disabled store, nothing matching) use the slice 01 pattern: `XCTFail`-ing hook + short sleep.
  Reset `storeProviderOverride = nil` in `setUp`/`tearDown` alongside the observers.

### `KeeForgeTests/CredentialIdentityStoreManagerTests.swift` (new cases)

Identifier format (pure, no fake needed):

- `testRecordIdentifierEncodedFormat` — `encoded` is exactly `"v2:" + databaseID.uuidString + ":" + entryID.uuidString`
  (pins the wire format literally so a format change is a conscious act).
- `testRecordIdentifierEncodeParseRoundTrip` — `parse(encoded)` returns `.current` with the same
  `databaseID`/`entryID`.
- `testParseBareEntryUUIDClassifiesAsLegacy` — `parse(uuid.uuidString)` (and its lowercased form, which
  `UUID(uuidString:)` accepts) → `.legacy(entryID: uuid)`.
- `testParseGarbageIsUnrecognized` — `"not-an-identifier"`, `""`, `"::"`.
- `testParseWrongVersionIsUnrecognized` — `"v1:<db>:<entry>"`, `"v3:<db>:<entry>"`, `"V2:<db>:<entry>"`
  (prefix is case-sensitive).
- `testParseTruncatedOrMalformedFieldsIsUnrecognized` — `"v2:<db>"` (two parts), `"v2:<db>:<entry>:extra"`
  (four parts), `"v2:junk:<entry>"`, `"v2:<db>:junk"`.
- `testParseResultConveniences` — `entryID` non-nil for `.current`/`.legacy`, nil for `.unrecognized`;
  `databaseID` non-nil only for `.current`.

Identity tagging (replaces the old `recordIdentifier == entry.id.uuidString` assertions):

- `testPasswordIdentitiesCarryTaggedRecordIdentifier` — every identity from `passwordIdentities(for:in:)`
  parses to `.current` with the given database id and the entry's UUID.
- `testPasskeyIdentityCarriesTaggedRecordIdentifier` — same via `passkeyIdentity(for:in:)`.
- `testOneTimeCodeIdentityCarriesTaggedRecordIdentifier` — same via `oneTimeCodeIdentity(for:in:)`
  (`@available(iOS 18.0, *)` test).
- Existing dedup/eligibility tests (multi-URL dedup, empty-username/password/domain rejections, multi-part
  TLD handling) are behavior-preserved — they only need the `, in:` migration above to keep passing.

Manager behavior against `FakeCredentialIdentityStore` (install via `storeProviderOverride`):

- `testPopulateReplacesStoreWithTaggedIdentities` — `populate(with:for:)` calls `replaceCredentialIdentities`
  once; every stored identity's `recordIdentifier` parses to `.current` owned by the given database.
- `testPopulateFiltersExpiredEntries` — an expired entry contributes no identity (expiry preserved
  post-refactor).
- `testPopulateWithNoEligibleEntriesEmptiesStore` — `removeAllCredentialIdentities` is called instead of
  replace (existing behavior, now assertable directly instead of via observer).
- `testTargetedRemovalRemovesOnlyTargetDatabase` — seed the fake with identities tagged for databases A and
  B plus one legacy and one garbage recordIdentifier; `removeIdentities(forDatabase: A)` removes exactly A's;
  B's, the legacy, and the garbage identity remain.
- `testTargetedRemovalIncludingLegacySweepsLegacyIdentifiers` — same seed,
  `removeIdentities(forDatabase: A, includingLegacyIdentifiers: true)` also removes the legacy identity;
  B's and the garbage one remain.
- `testTargetedRemovalWithNothingMatchingIsNoOp` — store holds only B's identities; removal for A performs
  no `removeCredentialIdentities` call (assert via `calls`).
- `testTargetedRemovalNeedsNoEntryData` — seed the fake, call `removeIdentities(forDatabase:)` with no
  `KPEntry` in sight; removal succeeds (pins "works with every database locked" — enumeration only).
- `testTargetedRemovalSkipsWhenEnumerationUnavailable` — `enumerationUnavailable = true`: no removal call
  (macOS 14.0–14.3 contract; callers fall back to `clearStore()`).
- `testRemoveIdentitiesForEntriesRebuildsTaggedIdentities` — `removeIdentities(for:in:)` passes identities
  whose recordIdentifiers equal the published encodings (pins the rebuild-identical removal contract).
- `testClearStoreEmptiesStore` — `clearStore()` → `removeAllCredentialIdentities`.
- `testDisabledStoreMakesEveryOperationANoOp` — `isEnabledValue = false`: `populate`, `clearStore`,
  `removeIdentities(for:in:)`, and `removeIdentities(forDatabase:)` all leave `stored` and `calls`
  untouched (system-settings-disabled edge; the OS already cleared the real store).
- `testRemoveDatabaseObserverReceivesDatabaseID` — `removeDatabaseObserver` fires with the id passed to
  targeted removal (and, since slice 04, the `includingLegacyIdentifiers` flag as its second argument —
  the seam slice 04's `DatabaseListStore` tests rely on).

### `KeeForgeTests/CredentialProviderCoordinatorTests.swift` (new cases)

Use the file's existing pattern: seed `parsedEntries`/`sessionKey` directly on the coordinator and drive it
with the existing `CredentialProviderPresenting` spy.

- `testPasswordFillResolvesCurrentFormatIdentifier` — `targetRecordIdentifier =
  CredentialRecordIdentifier(databaseID: anyID, entryID: entry.id).encoded`;
  `presentPasswordMatchesOrFinish()` completes with that entry's credential (no picker).
- `testPasswordFillResolvesLegacyIdentifier` — `targetRecordIdentifier = entry.id.uuidString`; same
  completion (pre-feature suggestions keep filling after update).
- `testUnrecognizedIdentifierFallsBackToInteractivePath` — `targetRecordIdentifier = "v9:garbage"`; the
  coordinator does not complete directly but falls through to matching/search presentation (never a dead tap).
- `testCurrentFormatIdentifierForForeignEntryFallsBack` — a tagged identifier whose entry UUID is not in
  `parsedEntries` (e.g. another database's entry) falls into the same fallback (documents pre-slice-03
  behavior: match is by entry UUID within the active database only).
- `testPasskeyLookupResolvesTaggedRecordIdentifier` — `passkeyEntry(for:)` path via
  `findEntry(byRecordIdentifier:)`: a passkey identity carrying a tagged identifier resolves to the entry
  (extend an existing passkey-assertion test's identity with the tagged string).
- `testOTCPendingRequestResolvesCurrentAndLegacyIdentifiers` — `completeOTCRequestFromPending()` with a
  tagged and then a legacy `targetRecordIdentifier` completes the OTC request; an unrecognized one falls
  back to `presentOTCMatchesOrFinish` (`@available(iOS 18.0, *)`).

### Run command

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/CredentialIdentityStoreManagerTests \
  -only-testing:KeeForgeTests/CredentialProviderCoordinatorTests -quiet
```

Then re-run the migrated suites:
`-only-testing:KeeForgeTests/DatabaseViewModelTests -only-testing:KeeForgeTests/CredentialProviderSaveTests
-only-testing:KeeForgeTests/PasskeyTests -only-testing:KeeForgeTests/DatabaseListStoreTests`.
Slice 02 edited no `.xcstrings` catalogs, so `swift scripts/normalize-xcstrings.swift` / `LocalizationTests`
are not required for this slice.

### Manual checks (device/simulator with the extension enabled)

- Unlock a database → QuickType suggestions appear and fill (tagged identifiers end-to-end).
- Suggestion published by a pre-feature build (legacy identifier) still fills after updating, before the
  first re-unlock replaces the store.
- Save an entry from the extension → suggestions refresh and fill.

---

## Slice 03: Extension identity-to-database resolution

### Implementation summary (what the tests pin down)

- `DatabaseListStore.defaultAutoFillDatabase` (new, shared with both extension targets) — the default
  database for identifier-less flows: private `activeAutoFillDatabase(in:)` (pointer-if-enabled → gated
  legacy-filename fallback; extracted verbatim from the getter, whose public behavior is unchanged), else the
  most recently opened reference with `autoFillEnabled && lastOpenedAt != nil`, else nil. Never returns a
  disabled database.
- `CredentialIdentityStoreManager.removeIdentity(withRecordIdentifier:)` (new) — enumerate the store, remove
  every identity whose `recordIdentifier` **equals the given string exactly** (an entry's password, passkey,
  and OTC identities share one identifier string, so all suggestion types for that entry go). Gated on
  `isEnabled()`; no-op with an error log when `credentialIdentities()` returns nil (macOS 14.0–14.3). New
  `#if DEBUG` seam: `removeIdentityObserver: ((String) -> Void)?` fires with the exact identifier string.
- Coordinator resolution (all in `CredentialProviderCoordinator`):
  - private `resolveRequestDatabase(forRecordIdentifier:)` → `.database(ref)` / `.stale(fallback:)` /
    `.unavailable`. Mapping: nil identifier → default database or `.unavailable`; `.current` → owning
    reference from `DatabaseListStore.databases` iff registered **and** `autoFillEnabled`, else schedules
    `removeIdentities(forDatabase: id)` and returns `.stale(fallback: default)`; `.legacy` → default
    database or `.unavailable`; `.unrecognized` → schedules `clearStore()` and returns `.stale`.
  - private `resolveInteractiveRequestDatabase()` — called at the top of `presentUnlockPromptIfNeeded()`;
    returns the already-pinned `activeDatabaseReference` if set, else resolves
    `targetRecordIdentifier` and pins the result. On `.stale` it **nils `targetRecordIdentifier`** (so the
    post-unlock lookup can't dead-end) and continues on the fallback; returns nil (→ empty state) for
    `.unavailable` or stale-without-fallback.
  - private `resolveSilentRequestDatabase(forRecordIdentifier:)` — same, but stale/unavailable → nil and the
    silent entry points cancel with `.userInteractionRequired` (system relaunches interactively).
  - Rerouted entry points: `provideCredentialWithoutUserInteraction(for: ASPasswordCredentialIdentity)`,
    `providePasskeyWithoutUserInteraction(for:)`, `provideOTCWithoutUserInteraction(for:)` (all resolve
    **before** the biometrics guard), and every interactive flow via `presentUnlockPromptIfNeeded()`.
    `prepareInterface(for: ASSavePasswordRequest)` now targets `defaultAutoFillDatabase` and pins
    `activeDatabaseReference` at prepare time; zero enabled → sets new internal flag
    `pendingNoEnabledDatabasesPresentation` (consumed by `presentationDidBecomeActive()`, reset by
    `clearPendingCreationRequests()`/`cleanup()`) instead of the old `cancelRequest(.failed)`.
    `performWithoutUserInteractionIfPossible(savePasswordRequest:)` still cancels `.userInteractionRequired`;
    generate-password flows still touch no database at all (deliberate).
  - `canUseBiometrics(for:)` / `shouldAutoUnlockWithBiometrics(for:)` are now parameterized on the resolved
    reference (keychain key + legacy filename of the *owning* database, never the active pointer's).
  - `currentDatabaseReference()` falls back to `defaultAutoFillDatabase` (was `activeAutoFillDatabase`) when
    nothing is pinned; `persistCompositeKeyIfPossible` refreshes `activeDatabaseReference` by **id** from
    `DatabaseListStore.databases` after legacy-keychain migration (no longer via the active pointer).
- Entry-missing-after-unlock cleanup: private `removeStaleIdentityIfEntryMissing(recordIdentifier:)` — only
  when `findEntry(byRecordIdentifier:)` over `parsedEntries` is nil (an existing-but-expired entry is left
  alone): `.current` → `removeIdentity(withRecordIdentifier:)`; `.legacy`/`.unrecognized` → `clearStore()`.
  Call sites: `presentPasswordMatchesOrFinish` (then falls through to matching/search), the silent password
  path (then strict-match fallback), both OTC paths (silent → `.credentialIdentityNotFound`; pending →
  `presentOTCMatchesOrFinish()`), and both passkey completion guards (then `.credentialIdentityNotFound`).
- Empty state: coordinator `presentNoEnabledDatabasesState()` → new `CredentialProviderPresenting`
  requirement `presentNoEnabledDatabasesState(onDismiss:)` → `AutoFillNoEnabledDatabasesView` (in
  `AutoFillSearchView.swift`, shared by both shells; `ContentUnavailableView` + toolbar Cancel). Dismissal
  cancels `.userCanceled`. Both shells (`CredentialProviderViewController` iOS + Mac) implement it.
- Access flips for testability (per this file's slice 02/03 sections): `completeOTCRequestFromPending()` and
  `completeInteractivePasskeyRequest(_:)` are now internal.
- Active-pointer semantics (deliberate): `recordSuccessfulUnlock` is unchanged — unlocking a resolved
  non-active database calls `markDatabaseOpened(id:)`, which updates `lastOpenedAt` **and moves the active
  pointer to it** (the slice 01 gated setter permits it because only enabled databases resolve).

### Required migrations of existing tests (compile/behavior fixes — do these first)

- `CredentialProviderCoordinatorTests.PresenterSpy` must implement the new protocol method — record it like
  the other prompts: `struct NoEnabledDatabasesState { let onDismiss: () -> Void }`, property
  `noEnabledDatabasesState`, assignment in `presentNoEnabledDatabasesState(onDismiss:)`.
- `test_cleanup_runsOnCancel` and `test_cleanup_runsOnError` drive `presentationDidBecomeActive()` with an
  **empty registry**; they now get the empty state instead of an unlock prompt. Seed a resolvable default
  first: `let reference = TestDatabaseSupport.makeReference(for: makeTemporaryFileURL(name:))`;
  `DatabaseListStore.update(reference)`; `DatabaseListStore.activeAutoFillDatabaseID = reference.id`
  (the pointer alone is not enough — `defaultAutoFillDatabase` requires the reference to be **registered**;
  registration alone is not enough either, because a never-opened reference has `lastOpenedAt == nil`).
  Unlock still fails in `test_cleanup_runsOnError` (no cached copy/bookmark → `showErrorAndRetry`).
- `CredentialProviderShellMacTests` and both shells compile unchanged apart from the added method; no
  behavior migration.

### Seams to use

- `CredentialIdentityStoreManager.storeProviderOverride` + the slice 02 `FakeCredentialIdentityStore`
  (install with `await MainActor.run { … }`, `onMutation` → expectation, reset in setUp/tearDown) for
  store-level assertions; the lighter observers `removeDatabaseObserver` / `removeIdentityObserver` /
  `clearObserver` for coordinator-level "which cleanup API fired" assertions (all fire via
  `Task { @MainActor … }` → `expectation` + `await fulfillment(of:timeout: 1)`; negative cases:
  `XCTFail`-ing observer + ~100 ms sleep).
- Coordinator vault seeding (class doc: state is internal for tests): `seedUnlockedVaultState(_:entries:sessionKey:)`
  plus direct writes to `targetRecordIdentifier`, `activeDatabaseReference`, `hasPendingOTCRequest`,
  `pendingNoEnabledDatabasesPresentation`, `serviceIdentifiers`.
- Registry seeding: `DatabaseListStore.clearAll()` in setUp/tearDown; `DatabaseListStore.update(_:)` to
  register references (extend the reference builders with `autoFillEnabled:`/`lastOpenedAt:` as slice 01
  documented); `DatabaseListStore.markDatabaseOpened(id:at:)` to control `lastOpenedAt` ordering;
  identifiers built with `CredentialRecordIdentifier(databaseID:entryID:).encoded`.
- `ASPasswordCredentialIdentity(serviceIdentifier:user:recordIdentifier:)` is publicly constructible for
  interactive-resolution tests; `BiometricService.isAvailable` is false under simulator tests, so silent
  paths short-circuit at the biometrics guard — silent-path resolution is asserted via the cleanup
  observers + the `.userInteractionRequired` cancellation, not via a completed fill.

### `KeeForgeTests/DatabaseListStoreTests.swift` (default-database order)

- `testDefaultAutoFillDatabaseReturnsEnabledPointerReference` — pointer at enabled A, B opened more
  recently: returns A (pointer wins over recency).
- `testDefaultAutoFillDatabasePrefersLegacyFallbackOverMostRecentlyOpened` — pointer nil, A with
  `legacyKeychainFilename` set (enabled, never opened), B enabled and opened: returns A (the
  `activeAutoFillDatabase` chain, including its legacy fallback, takes precedence; recency is only the
  final fallback).
- `testDefaultAutoFillDatabaseFallsBackToMostRecentlyOpenedEnabled` — pointer nil, no legacy references,
  A opened at t1, B opened at t2 > t1: returns B; disable B → returns A (disabled skipped).
- `testDefaultAutoFillDatabaseIgnoresNeverOpenedReferences` — pointer nil, one enabled reference with
  `lastOpenedAt == nil`: returns nil.
- `testDefaultAutoFillDatabaseNilWithZeroEnabledDatabases` — all references disabled (or registry empty):
  returns nil.
- Slice 01's `activeAutoFillDatabase` tests must stay green unmodified (pins that the `activeAutoFillDatabase(in:)`
  extraction changed nothing for existing callers).

### `KeeForgeTests/CredentialIdentityStoreManagerTests.swift` (single-identity removal)

Against `FakeCredentialIdentityStore` via `storeProviderOverride`:

- `testRemoveIdentityWithRecordIdentifierRemovesAllTypesForThatIdentifierOnly` — seed password + passkey
  (+ OTC where available) identities for entries A and B (distinct encoded identifiers);
  `removeIdentity(withRecordIdentifier: aID)` removes every identity carrying exactly `aID`; B's remain.
- `testRemoveIdentityWithRecordIdentifierNoMatchIsNoOp` — unknown identifier: no
  `removeCredentialIdentities` call recorded in `calls`.
- `testRemoveIdentityWithRecordIdentifierSkipsWhenEnumerationUnavailable` — `enumerationUnavailable = true`:
  no removal (macOS 14.0–14.3 contract).
- `testRemoveIdentityWithRecordIdentifierNoOpWhenStoreDisabled` — `isEnabledValue = false`: untouched.
- `testRemoveIdentityObserverReceivesExactIdentifierString` — observer fires with the string passed in.

### `KeeForgeTests/CredentialProviderCoordinatorTests.swift` (resolution + stale handling + empty state)

Resolution (interactive; drive `prepareInterfaceToProvideCredential(for:)` +
`presentationDidBecomeActive()`, then inspect `coordinator.activeDatabaseReference` / `presenter.unlockPrompt`):

- `test_resolution_currentIdentifierPinsOwningDatabaseNotActivePointer` — register enabled A and B, pointer
  at A; identity `recordIdentifier = CredentialRecordIdentifier(databaseID: B.id, entryID: e).encoded`:
  unlock prompt is presented and `activeDatabaseReference?.id == B.id` (the unlock/biometric/key/load
  pipeline all key off this pin; this is the "unlocks *that* database" contract).
- `test_resolution_legacyIdentifierPinsDefaultDatabase` — bare-UUID identifier, pointer at A:
  `activeDatabaseReference?.id == A.id` and `targetRecordIdentifier` is preserved (legacy still fills).
- `test_resolution_unknownDatabaseRemovesItsIdentitiesAndFallsBackToDefault` — identifier tagged with an
  unregistered UUID: `removeDatabaseObserver` fires with that UUID, `targetRecordIdentifier` becomes nil,
  pin lands on default A, unlock prompt presented (never a dead tap).
- `test_resolution_disabledDatabaseTreatedAsUnknown` — B registered with `autoFillEnabled == false`,
  identifier tagged B: `removeDatabaseObserver` fires with `B.id`, fallback to A as above.
- `test_resolution_unrecognizedIdentifierClearsStoreAndFallsBack` — `recordIdentifier = "v9:garbage"`:
  `clearObserver` fires, fallback to default A, unlock prompt presented.
- `test_resolution_staleIdentifierWithZeroEnabledDatabasesShowsEmptyState` — empty registry + tagged
  identifier: `presenter.noEnabledDatabasesState` set, no unlock prompt; its `onDismiss()` →
  `cancelledError == .userCanceled` + `assertCleanedUp`.
- `test_manualListWithZeroEnabledDatabasesShowsEmptyState` — `prepareCredentialList(for:)` on an empty
  registry (and again with one disabled reference): empty state instead of unlock prompt.
- `test_presentationDidBecomeActive_pendingNoEnabledDatabasesFlag_presentsEmptyState` — set
  `pendingNoEnabledDatabasesPresentation = true` (the save-prepare deferral), `pendingUnlock = false`, call
  `presentationDidBecomeActive()`: empty state presented and the flag consumed. This is the testable half
  of the save-unavailable path; see the save section below for the request-object caveat.

Entry missing after successful unlock (seed the vault, no real unlock needed):

- `test_passwordFill_missingEntryRemovesThatIdentityAndFallsBackToSearch` — seed entries *without* the
  target; `targetRecordIdentifier = v2:<db>:<missingEntry>`; `presentPasswordMatchesOrFinish()`:
  `removeIdentityObserver` fires with the exact identifier and the search view is presented.
- `test_passwordFill_missingLegacyEntryClearsStore` — bare-UUID target not in entries: `clearObserver`
  fires; search view still presented.
- `test_passwordFill_expiredEntryIsNotTreatedAsMissing` — target entry present but expired: neither
  observer fires (XCTFail observer + sleep); interactive fallback as before.
- `test_otcPending_missingEntryRemovesIdentityAndPresentsPicker` (`@available(iOS 18.0, *)`) — seed TOTP
  entries, `targetRecordIdentifier` tagged for a missing entry, call `completeOTCRequestFromPending()`
  (now internal): `removeIdentityObserver` fires, picker presented (`presentOTCMatchesOrFinish` fallback).
- `test_interactivePasskey_missingEntryRemovesIdentityAndCancelsNotFound` — build an
  `ASPasskeyCredentialRequest` whose identity (`ASPasskeyCredentialIdentity(relyingPartyIdentifier:userName:credentialID:userHandle:recordIdentifier:)`)
  carries a tagged identifier for an entry absent from the seeded vault; `completeInteractivePasskeyRequest(_:)`
  (now internal): `removeIdentityObserver` fires, `cancelledError == .credentialIdentityNotFound`.
- `test_passkeyResolution_recordIdentifierStillResolvesEntry` — regression on slice 02's
  `passkeyEntry(for:)` path: a seeded passkey entry with matching tagged identifier completes assertion
  (proves resolution changes didn't break the happy path).

Silent-path resolution (biometrics unavailable under test, so assert cleanup + cancellation):

- `test_silentFill_staleIdentifierCleansUpAndCancelsUserInteractionRequired` —
  `provideCredentialWithoutUserInteraction(for:)` with an unknown-database identity:
  `removeDatabaseObserver` fires and `cancelledError == .userInteractionRequired` (interactive relaunch
  contract); same shape for `.unrecognized` → `clearObserver`.
- `test_silentFill_zeroEnabledDatabasesCancelsUserInteractionRequired` — empty registry, identifier-less
  identity: `.userInteractionRequired`, no observer fires.

### `KeeForgeTests/CredentialProviderSaveTests.swift` (save targets the default enabled database)

- `test_saveNewEntry_*` existing tests stay green (the save engine itself is untouched by this slice).
- `test_defaultDatabaseSelectionForSave` — the coordinator's save-prepare targeting is
  `DatabaseListStore.defaultAutoFillDatabase` + the `activeDatabaseReference` pin; the selection ordering is
  fully covered by the `DatabaseListStoreTests` cases above. Driving `prepareInterface(for:
  ASSavePasswordRequest)` directly requires constructing an `ASSavePasswordRequest` (iOS 26.2; check on a
  Mac whether it is test-constructible — it was not verifiable in this environment). If it is: assert (a)
  with A enabled+opened and B disabled, prepare pins A even when B was opened later; (b) with zero enabled
  databases, `pendingUnlock == false` and `pendingNoEnabledDatabasesPresentation == true` (no `.failed`
  cancellation). If it is not constructible, the pin + flag behavior is already covered by
  `test_presentationDidBecomeActive_pendingNoEnabledDatabasesFlag_presentsEmptyState` plus the store tests;
  document the gap inline in the test file.

### Optional (mac shell)

- `CredentialProviderShellMacTests`: `test_presentNoEnabledDatabasesState_hostsEmptyStateAndDismissCancels`
  — shell hosts `AutoFillNoEnabledDatabasesView` (`isDisplayingContent == true`), invoking `onDismiss`
  routes through the coordinator to `cancelRequest` on the injected `requestCompleter`.

### Run command

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/CredentialProviderCoordinatorTests \
  -only-testing:KeeForgeTests/CredentialProviderSaveTests \
  -only-testing:KeeForgeTests/CredentialIdentityStoreManagerTests \
  -only-testing:KeeForgeTests/DatabaseListStoreTests -quiet
```

### Toolchain notes for this slice

- **Strings:** two new keys in `AutoFillExtension/Localizable.xcstrings` (used by both extension targets;
  `InfoPlist.xcstrings` untouched): `"No Databases for AutoFill"` and
  `"Turn on AutoFill for a database in KeeForge’s settings to use it here."` (note the U+2019 apostrophe —
  the SwiftUI literal and the catalog key must stay byte-identical), each with a translated `de` unit; the
  empty state's button reuses the existing `"Cancel"` key. Run `swift scripts/normalize-xcstrings.swift` on
  a Mac (key order was inserted per `localizedStandardCompare` by hand) and then
  `-only-testing:KeeForgeTests/LocalizationTests`.
- **New accessibility identifiers:** `autofill.no-enabled-databases` (empty-state label) and
  `autofill.no-enabled-databases.cancel` (its Cancel action). All existing search/creator identifiers are
  preserved.
- No new files; `project.yml` untouched (all changes live in files already in the app target and both
  extension allow-lists).

### Manual checks (device + mac extension smoke)

- Two databases set up and unlocked at least once each: tap a QuickType suggestion belonging to the
  *non-active* database → that database's biometric/password unlock → fill completes; the active pointer
  now follows the tapped database.
- Disable AutoFill for the only database, invoke AutoFill manually → empty state with the settings hint;
  Cancel returns to the caller. Save-password sheet likewise shows the empty state instead of failing.
- Remove a database from the app, tap one of its lingering suggestions → interactive fallback on the
  remaining database (or empty state) and the suggestion disappears afterward.
- Delete a single entry, unlock via its stale suggestion → falls back to search and exactly that
  suggestion disappears; other suggestions survive.
- Edge cases: locked owning database (unlock prompt, silent request → `userInteractionRequired`), cloud
  database with cache-only access, biometric-cancel falling back to the password prompt, extension launch
  right after the system cleared the store.

---

## Slice 04: Multi-database aggregation and targeted removal

### Implementation summary (what the tests pin down)

- `CredentialIdentityStoreManager.populate(with:for:)` **kept its name** (all callers —
  `DatabaseViewModel.populateCredentialStoreIfNeeded`, `AutoFillSaveCoordinator.Environment.live` —
  are unchanged) but is now a **per-database refresh** with this decision tree, run inside its
  fire-and-forget `Task` after the `isEnabled()` gate and identity building:
  1. Enumerate via `store.credentialIdentities()`.
  2. If enumeration returned **nil** (macOS 14.0–14.3) **or** no stored identity parses to
     `.current` with a *different* database id → atomic whole-store path exactly as pre-slice-04:
     `replaceCredentialIdentities(databaseIdentities)`, or `removeAllCredentialIdentities()` when
     the refreshing database has no eligible identities. (Also purges `.legacy` and
     `.unrecognized` identifiers as a side effect of the full replace.)
  3. Otherwise (another database's identities are present) → additive refresh: one
     `removeCredentialIdentities` for the subset parsing to `.current` owned by the refreshing
     database **plus** every `.legacy` identity (skipped when that subset is empty), then one
     `saveCredentialIdentities(databaseIdentities)` (skipped when the new set is empty — so an
     emptied database removes only its own + legacy identities and other databases keep theirs;
     `removeAll` never runs on this branch). `.unrecognized` identifiers are left untouched on
     this branch.
  - Expired-entry filtering, the `populateObserver` firing shape `(databaseID, eligibleEntries)`,
    off-main execution, and count-only (secret-free) logging are unchanged.
- `DatabaseListStore.setAutoFillEnabled(_:for:)` **off** no longer calls `clearStore()`:
  it calls `CredentialIdentityStoreManager.removeIdentities(forDatabase: reference.id,
  includingLegacyIdentifiers: wasActive)` for **every** disable (active or not), and reassigns the
  pointer via `nextActiveAutoFillDatabaseID(excluding:)` only when `wasActive` (`wasActive` is
  resolved through `activeAutoFillDatabase`, so a legacy-fallback-active database counts).
  Rationale for the flag: legacy bare-UUID identities were only ever published by the
  whole-store-replace era's single active database, so they belong to the disabled database
  exactly when it was the active one.
- `DatabaseListStore.remove(id:)` now calls `removeIdentities(forDatabase: id,
  includingLegacyIdentifiers: wasActiveAutoFillDatabase)` for **every** removal (pre-slice-04 only
  an *active* removal cleared anything, and it wiped the whole store). Pointer cleanup is
  unchanged: `activeAutoFillDatabaseID` goes to `nil` when it pointed at the removed id (removal
  does *not* hand off to the next-most-recent database; only disable does).
- `DatabaseListViewModel` gained `autoFillEnabledRefreshHandler: ((UUID) -> Void)?`;
  `setAutoFillEnabled(_:for:)` invokes it with `reference.id` after store delegation + `reload()`
  **only when enabling**. `AppRootView` (in `KeeForgeApp.swift`) installs the production handler in
  its `.task`: it captures the `$activeDatabaseViewModel` binding and calls
  `populateCredentialStoreIfUnlocked()` when the enabled id matches the active session's
  `databaseReference.id` (no-op otherwise — enabling any other database stays lazy).
  `populateCredentialStoreIfUnlocked()` itself guards on `rootGroup != nil` (nil while locked) and
  re-reads the registry flag, so the handler is safe to call unconditionally.
- `SettingsView`'s global Quick AutoFill handler is behaviorally unchanged (comment only): **on**
  still calls `viewModel?.populateCredentialStoreIfUnlocked()` — the app's single open session is
  "every currently unlocked database", and the slice 01 registry gate inside
  `populateCredentialStoreIfNeeded` already restricts it to an *enabled* database; **off** still
  calls `clearStore()`.
- `AutoFillSaveCoordinator.saveNewEntry` needed no change: its
  `environment.populateCredentialStore` → `populate(with:for:)` call is now a per-database refresh
  automatically, so an in-extension save no longer wipes other databases' suggestions.
- Seam change: `removeDatabaseObserver` is now `((UUID, Bool) -> Void)?` — fires with
  `(databaseID, includingLegacyIdentifiers)`.
- macOS 14.0–14.3 (no enumeration API): `populate` always takes the whole-replace branch and the
  targeted removals in `removeIdentities(forDatabase:)` log-and-skip — i.e. the platform keeps the
  pre-aggregation single-active behavior end to end; a disabled/removed database's suggestions
  linger there until any enabled database's next refresh whole-replaces the store.

### Required migrations of existing/earlier-documented tests (behavior changed in this slice)

- **Existing committed test**
  `DatabaseListStoreTests.testRemoveClearsCredentialStoreWhenRemovingActiveAutoFillDatabase`
  now fails as written: `remove(id:)` no longer calls `clearStore()`. Rewrite it (suggested name
  `testRemoveActiveDatabaseTriggersTargetedRemovalIncludingLegacy`) to expect
  `removeDatabaseObserver` firing with `(first.id, true)` and keep the
  `activeAutoFillDatabaseID == nil` assertion; additionally assert `clearObserver` stays silent.
- **Existing committed test**
  `DatabaseListStoreTests.testRemoveDoesNotClearCredentialStoreWhenRemovingInactiveDatabase`
  still passes as written (`clearObserver` is still untouched); optionally extend it to assert
  `removeDatabaseObserver` now fires with `(second.id, false)`.
- **Slice 01 documented cases** (not yet written): in
  `testDisablingActiveDatabaseClearsStoreAndReassignsPointer` and
  `testDisablingActiveDatabaseWithNoOtherOpenedEnabledDatabaseClearsPointer`, replace the
  `clearObserver` expectation with `removeDatabaseObserver` firing `(reference.id, true)` (pointer
  assertions unchanged; rename accordingly, e.g.
  `testDisablingActiveDatabaseTargetedRemovesAndReassignsPointer`).
  `testDisablingInactiveDatabaseLeavesStoreAndPointerUntouched`: the pointer assertion and the
  negative `clearObserver` assertion stand, but disabling an inactive database now *does* fire
  `removeDatabaseObserver` with `(reference.id, false)` — assert that instead of "nothing happens".
  `testSetAutoFillEnabledOnLockedDatabaseNeedsNoUnlock`: "still clears/reassigns" becomes "still
  targeted-removes/reassigns". `testEnablingDisabledDatabaseDoesNotPopulateOrClaimPointer` is
  still correct at the store layer (store-level enable stays lazy; immediacy lives in the
  view-model hook, tested below).
- **Slice 03 documented cases** that install `removeDatabaseObserver` closures
  (`test_resolution_unknownDatabaseRemovesItsIdentitiesAndFallsBackToDefault`,
  `test_resolution_disabledDatabaseTreatedAsUnknown`,
  `test_silentFill_staleIdentifierCleansUpAndCancelsUserInteractionRequired`): the closure now
  takes two arguments — use `{ id, _ in … }`; the coordinator's cleanup calls pass the default
  `includingLegacyIdentifiers: false`.

### Seams to use

- `FakeCredentialIdentityStore` (slice 02 infrastructure) via `storeProviderOverride`, installed
  with `await MainActor.run { … }`; mutation expectations through its `onMutation` hook; negative
  cases via `XCTFail`-ing hook + ~100 ms sleep. Seed multi-database state by pre-filling
  `fake.stored` with identities built by the real builders
  (`passwordIdentities(for:in:)` / `passkeyIdentity(for:in:)`) plus hand-made
  `ASPasswordCredentialIdentity(serviceIdentifier:user:recordIdentifier:)` for legacy
  (`entryID.uuidString`) and garbage (`"not-an-identifier"`) identifiers.
- **Fake addition for this slice:** give the fake an enumeration hook,
  `var onEnumerate: (@Sendable () -> Void)?`, invoked inside `credentialIdentities()` before
  returning — the "store cleared externally between enumerate and mutate" edge case empties
  `fake.stored` from that hook mid-refresh.
- Observers: `populateObserver` (`(UUID, [KPEntry])`), `clearObserver`, and the two-argument
  `removeDatabaseObserver` (`(UUID, Bool)`), reset in `setUp`/`tearDown` as before.
- View-model layer: `DatabaseListViewModel.autoFillEnabledRefreshHandler` is a plain settable
  closure — tests install their own handler (mirroring `AppRootView`'s) that calls
  `databaseViewModel.populateCredentialStoreIfUnlocked()`, so the production wiring's behavior is
  reproduced without SwiftUI. Existing helpers: `makeViewModel(reference:)`, fixture passwords,
  `DatabaseListStore.update(_:)` / `markDatabaseOpened(id:at:)` / `clearAll()`.

### `KeeForgeTests/CredentialIdentityStoreManagerTests.swift` (new cases, fake store)

Refresh decision tree:

- `testRefreshOfTwoDatabasesYieldsUnion` — `populate(with: aEntries, for: a)` then
  `populate(with: bEntries, for: b)`: the store ends holding A's *and* B's identities (first call
  whole-replaces, second detects A's tagged identities and goes additive — assert `calls` shows
  `replace` then `remove`/`save`, not two `replace`s).
- `testRefreshUsesWholeStoreReplaceWhenNoOtherDatabasePresent` — store empty (and again seeded
  with only A's own stale identities): `populate(with:for: a)` records exactly one
  `replaceCredentialIdentities`, no `saveCredentialIdentities`.
- `testRefreshAfterEntryDeletionRemovesOnlyThatEntrysIdentities` — seed A(e1, e2) + B(e3);
  `populate(with: [e1], for: a)`: e2's identities are gone, e1's present, B's untouched (the
  deleted-entries-never-linger guarantee, no periodic sweep).
- `testRefreshPurgesLegacyIdentifiers` — seed one legacy bare-UUID identity + B's tagged ones;
  `populate(with:for: a)`: legacy removed, B intact, A's set saved.
- `testRefreshLeavesUnrecognizedIdentifiersInAdditiveMode` — seed a garbage-identifier identity +
  B's; refresh A: the garbage identity survives (documented: it dies only via whole-store replace
  or `clearStore()`).
- `testRefreshWithNoEligibleEntriesRemovesOwnAndLegacyOnlyWhenOthersPresent` — seed A + B +
  legacy; `populate(with: [], for: a)`: A's and the legacy identity are removed, B's remain, and
  `removeAllCredentialIdentities` is **not** called.
- `testRefreshWithNoEligibleEntriesAndNoOthersEmptiesStore` — seed only A's identities;
  `populate(with: [], for: a)`: `removeAllCredentialIdentities` (pre-aggregation behavior kept).
- `testRefreshFallsBackToWholeReplaceWhenEnumerationUnavailable` — `enumerationUnavailable =
  true`, seed B's identities; refresh A: `replaceCredentialIdentities` wipes B (macOS 14.0–14.3
  contract — other databases repopulate lazily on next unlock).
- `testRefreshSurvivesStoreClearedBetweenEnumerateAndMutate` — via `onEnumerate` empty
  `fake.stored` after seeding B (so the refresh decided "additive" on stale data): the refresh
  completes without error and A's identities are saved (briefly-stale worst case accepted by the
  epic).
- `testDisabledStoreNoOpsRefresh` — `isEnabledValue = false`: `populate` records no calls at all
  (extends slice 02's `testDisabledStoreMakesEveryOperationANoOp` to the new enumerate path).
- Slice 02's `testPopulateFiltersExpiredEntries` and the tagging tests stay green unmodified
  (filtering and identity building are untouched).

### `KeeForgeTests/DatabaseViewModelTests.swift` (new cases, observers + fake store)

- `testUnlockRefreshesOnlyTheUnlockedDatabase` — seed the fake with B's tagged identities,
  persist + unlock enabled database A: `populateObserver` fires once with A's id, and after
  `onMutation` settles the fake still contains B's identities alongside A's (unlock no longer
  wipes other databases).
- `testGlobalToggleOnRefreshesOnlyUnlockedEnabledDatabase` — the SettingsView "on" path is
  `populateCredentialStoreIfUnlocked()`: with the open database enabled it fires
  `populateObserver` with that database's id; with the open database disabled in the registry it
  stays silent (slice 01's `testPopulateCredentialStoreIfUnlockedRereadsFlagFromRegistry` already
  pins the silent half — reference it rather than duplicating).
- `testToggleOnOfOpenDatabaseRefreshesImmediatelyThroughHandler` — unlock database A; build a
  `DatabaseListViewModel` and install
  `listViewModel.autoFillEnabledRefreshHandler = { id in guard id == viewModel.databaseReference.id
  else { return }; viewModel.populateCredentialStoreIfUnlocked() }` (the `AppRootView` wiring);
  `listViewModel.setAutoFillEnabled(false, for: aRef)` then `(true, for: aRef)`:
  `populateObserver` fires with A's id after the re-enable (immediate refresh through the hook,
  no re-unlock).
- `testToggleOnOfNonOpenDatabaseStaysLazy` — same handler; enable a *different* registered
  database: `populateObserver` never fires (XCTFail observer + sleep) — lazy until its unlock.
- `testToggleOffOfBackgroundDatabaseTriggersRemovalNotClear` — with A unlocked,
  `listViewModel.setAutoFillEnabled(false, for: bRef)` (B locked, not active):
  `removeDatabaseObserver` fires with `(b.id, false)`; `clearObserver` and the handler stay
  silent.

### `KeeForgeTests/DatabaseListStoreTests.swift` (new cases)

- `testRemovingNonActiveDatabaseTriggersTargetedIdentityRemoval` — pointer at `first`;
  `remove(id: second.id)`: `removeDatabaseObserver` fires with `(second.id, false)`, pointer still
  `first.id`, `clearObserver` silent (fixes the epic's "removal gap"; complements the migrated
  active-removal test above).
- `testRemovalWorksWithEverythingLocked` — references added but never unlocked (no composite key,
  no cached copy, no `KPEntry` anywhere); seed the fake with identities tagged for the removed id:
  `remove(id:)` removes exactly that subset — pure enumeration, no entry data.
- `testDisablingActiveDatabasePassesLegacyFlag` / `testDisablingInactiveDatabasePassesFalse` —
  covered by the migrated slice 01 cases above; keep the flag assertions there rather than adding
  duplicates.

### Run command

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/CredentialIdentityStoreManagerTests \
  -only-testing:KeeForgeTests/DatabaseViewModelTests \
  -only-testing:KeeForgeTests/DatabaseListStoreTests -quiet
```

Slice 04 edited no `.xcstrings` catalogs (no new user-facing strings), added no files
(`project.yml` untouched), and changed no accessibility identifiers. CHANGELOG is explicitly
deferred to the epic's slice 05 entry.

### Edge cases that apply (from the slice spec)

- All databases locked during removal → `testRemovalWorksWithEverythingLocked`.
- Store cleared externally between enumerate and mutate →
  `testRefreshSurvivesStoreClearedBetweenEnumerateAndMutate` (unit) + manual.
- In-extension save racing a main-app refresh → not unit-testable (two processes); manual check
  below; the accepted worst case is a briefly stale/duplicate suggestion until the next refresh.
- Background→foreground refresh → slice 01's foreground-refresh tests plus
  `testUnlockRefreshesOnlyTheUnlockedDatabase` cover the path
  (`refreshCredentialStoreForCurrentTreeIfNeeded` funnels into the same refresh).

### Manual checks (device, extension enabled)

- Unlock Personal, then Work: QuickType shows entries from both; each fills via its owning
  database (slice 03 resolution).
- Delete an entry from Work and save: only that suggestion disappears.
- Disable Work while locked: its suggestions vanish, Personal's remain; re-enable while Work is
  open in the app: suggestions reappear without re-unlock.
- Remove Work from the app while locked and not active: its suggestions vanish, Personal's remain.
- Save a new credential from the extension while the main app has another database unlocked:
  both databases' suggestions coexist afterwards.

---

## Slice 05: Settings UI and Clear AutoFill Entries

### Implementation summary (what the tests pin down)

- `DatabaseDetailsView` (in `KeeForge/Views/DatabaseListView.swift`) gained an "AutoFill" section
  (between Editing and Key File), mirroring the Read-only idiom exactly: a
  `Toggle("Include in AutoFill")` bound via `Binding(get: { currentReference.autoFillEnabled },
  set: { viewModel.setAutoFillEnabled($0, for: reference) })`, accessibility id
  `database-details.autofill-toggle`, footer stating the full scope (passwords, passkeys,
  verification codes neither suggested nor available while off; suggestions return on next
  unlock after re-enable). `viewModel` here is the app's shared `DatabaseListViewModel`, whose
  `autoFillEnabledRefreshHandler` AppRootView installed (slice 04) — so both toggle directions
  take immediate effect for the open database.
- `SettingsView` gained `var listViewModel: DatabaseListViewModel? = nil`. Passers of the app
  instance: the database list's settings sheet (`SettingsView(listViewModel: viewModel)` in
  `DatabaseListView.swift`) and the macOS Settings scene
  (`SettingsView(viewModel:listViewModel:)` in `KeeForgeApp.swift`). The open-database App
  Settings path (`DatabaseSettingsView` → `SettingsView(viewModel:)` in `GroupListView.swift`,
  iOS-only — macOS uses a `SettingsLink` to the scene) cannot reach the app instance, so
  `SettingsView.installFallbackListViewModelIfNeeded()` (called from the shared
  `applyingChangeHandlers` `.onAppear`) builds a local `DatabaseListViewModel` stored in
  `@State fallbackListViewModel` and installs the **same bridge AppRootView installs**, closed
  over the sheet's session `viewModel` (`guard id == sessionViewModel.databaseReference.id`,
  then `populateCredentialStoreIfUnlocked()`); that session is the app's only unlocked
  database, so enable-while-unlocked immediacy is preserved on every path.
  `resolvedListViewModel` (`listViewModel ?? fallbackListViewModel`) feeds the AutoFill
  `NavigationLink` destination (wrapped in `if let`; always non-nil after first `onAppear`).
- `AutoFillSettingsView` (in `KeeForge/Views/SettingsView.swift`) now takes
  `let listViewModel: DatabaseListViewModel` (non-optional) and calls `listViewModel.reload()`
  on appear. New UI, all routed through `DatabaseListViewModel.setAutoFillEnabled` — **never**
  `DatabaseListStore` directly:
  - `databasesSection`: header "Databases"; one `Toggle(reference.displayName)` per registered
    database bound like the details toggle, id
    `settings.autofill.database-toggle.<DatabaseReference.id.uuidString>` (uppercase UUID, the
    `WhatsNewView`/`AttachmentsSection` interpolation convention); empty-state line
    "No databases added yet" when zero registered; footer warning
    "AutoFill is on, but no databases are selected." shown iff `quickAutoFillEnabled` is true
    and no registered database has `autoFillEnabled` (also shows alongside the empty state —
    deliberate).
  - `clearEntriesSection`: destructive `Button("Clear AutoFill Entries")`
    (`settings.autofill.clear-entries`) → `confirmationDialog("Clear AutoFill Entries?")` with
    destructive `Button("Clear Entries")` (`settings.autofill.clear-entries.confirm`) calling
    `CredentialIdentityStoreManager.clearStore()`, plus a Cancel button. Deliberately **no
    republish** after clearing (empty store now; rebuild on next unlock of enabled databases).
  - The Quick AutoFill footer's stale single-active sentence ("KeeForge currently autofills
    from the last database you successfully opened.") was replaced by
    "KeeForge suggests credentials from the databases selected below." (old key removed from
    the catalog); the keyboard-bar sub-line is unchanged.
- Two surfaces, one state: both surfaces bind through the same `@Observable` view model and
  `setAutoFillEnabled` ends in `reload()`, so a flip in either place re-renders the other.
- `AutoFillSettingsView` compiles into `KeeForgeMac` (shared file) but is unreachable there
  (`macSettingsTabs` has no AutoFill tab); the fallback never activates on macOS because the
  Settings scene passes the app instance. No `SettingsService` change; no new files;
  `project.yml` untouched.

### Seams to use

- `CredentialIdentityStoreManager.removeDatabaseObserver` (`(UUID, Bool)` — id +
  `includingLegacyIdentifiers`), `populateObserver` (`(UUID, [KPEntry])`), `clearObserver`
  (`() -> Void`): all `#if DEBUG` `@MainActor` statics firing via `Task { @MainActor in … }` —
  positive assertions use `expectation` + `await fulfillment(of:timeout: 1)`, negative ones the
  `XCTFail`-ing observer + ~100 ms sleep pattern; reset all to nil in `setUp`/`tearDown`.
- `DatabaseListViewModel.autoFillEnabledRefreshHandler` — plain settable closure; tests install
  a recording closure directly (no SwiftUI needed) to pin when the view model invokes it.
- Existing `DatabaseListViewModelTests` fixtures: `DatabaseListStore.clearAll()` in
  `setUp`/`tearDown` (already present), `makeTemporaryFileURL(name:)`,
  `DatabaseListStore.add(url:)` / `update(_:)` / `markDatabaseOpened(id:)`.

### `KeeForgeTests/DatabaseListViewModelTests.swift` (the existing home of `setReadOnly` coverage)

- `testSetAutoFillEnabledFalsePersistsAndTriggersTargetedRemoval` *(new)* — add one reference;
  `viewModel.setAutoFillEnabled(false, for: reference)`: the flag sticks on a fresh
  `DatabaseListStore.databases` read **and** on `viewModel.databases` (the `reload()` half),
  `DatabaseListStore.autoFillEnabledDatabases` excludes it, and `removeDatabaseObserver` fires
  with `(reference.id, _)` — proves the view model routes through
  `DatabaseListStore.setAutoFillEnabled` (slice-04 targeted removal), not the generic `update`
  bypass. Assert `clearObserver` stays silent. (Supersedes slice 01's optional
  `testSetAutoFillEnabledDelegatesToStoreAndReloads`.)
- `testSetAutoFillEnabledTrueInvokesRefreshHandlerWithDatabaseID` *(new)* — install a recording
  `autoFillEnabledRefreshHandler`; disable then re-enable the reference: the handler is called
  exactly once, with `reference.id`, and only for the enable (this is the seam the settings
  toggles rely on for enable-while-unlocked immediacy; the full unlock-session integration is
  slice 04's `DatabaseViewModelTests.testToggleOnOfOpenDatabaseRefreshesImmediatelyThroughHandler`
  — do not duplicate it here).
- `testSetAutoFillEnabledFalseDoesNotInvokeRefreshHandler` *(new)* — recording handler + disable
  only: handler never called (disable is removal-only; nothing to republish).
- `testDisablingActiveDatabaseThroughViewModelReassignsPointerAndPassesLegacyFlag` *(new)* —
  two references, both `markDatabaseOpened`, pointer on the first;
  `viewModel.setAutoFillEnabled(false, for: first)`: `removeDatabaseObserver` fires with
  `(first.id, true)` and `DatabaseListStore.activeAutoFillDatabaseID` moves to the second —
  the slice-01/04 store consequences run unchanged when driven through the UI's entry point.
- The store-layer disable/enable matrix (locked databases, legacy fallback, sweep bypass) is
  fully documented in slices 01 and 04 under `DatabaseListStoreTests` — slice 05 adds no store
  behavior, so nothing new there.

### `KeeForgeTests/SettingsServiceTests.swift` — unchanged semantics (note only)

Slice 05 touched neither `SettingsService` nor the global Quick AutoFill `onChange` handler
(behaviorally final since slice 04): `quickAutoFillEnabled` still defaults to true and
persists to the shared-defaults key `KeeForge.quickAutoFillEnabled`. No new cases; just re-run
`-only-testing:KeeForgeTests/SettingsServiceTests` to confirm green.

### UI tests (XCUITest)

**Finding:** no existing UI test covers the database-details sheet today — grepping
`KeeForgeUITests/` for `database-details` (and `database-row.details`) has zero hits. The
home-screen list class is `DatabaseListUITests` (`KeeForgeUITests/DatabaseListUITests.swift`);
the settings flow lives in `AppSettingsUITests` (base `AppSettingsUITestCase` with
`openAppSettings()` / `revealInSettings(_:)` / `closeSettings()`, both in
`KeeForgeUITests/UnlockedDatabaseUITests.swift`). Keep to those two classes; run one class at a
time per `KeeForgeUITests/README.md`.

- `DatabaseListUITests.testDatabaseDetailsAutoFillTogglePersistsAcrossReopen` *(new)* —
  long-press the first `database.row`, tap the context-menu action `database-row.details`;
  assert the sheet shows the switch `database-details.autofill-toggle` with value `"1"`
  (`(toggle.value as? String) == "1"`; default enabled); flip it; close via
  `database-details.close`; reopen the same row's details sheet and assert the value is now
  `"0"` — persistence through `database-list.json` across sheet reopen. (Flip it back — or rely
  on the base class's per-test fixture reseed — so later tests see the default.) All existing
  `database-details.*` ids (`nickname-field`, `quick-launch-toggle`, `key-file-select`,
  `close`) and `database-row.*` ids are unchanged.
- `AppSettingsUITests.testAutoFillSettingsListsDatabaseTogglesAndCancelableClear` *(new)* —
  `openAppSettings()`; tap `settings.autofill.link`; assert at least one per-database toggle
  exists via `app.switches.matching(NSPredicate(format: "identifier BEGINSWITH
  'settings.autofill.database-toggle.'"))` (the suffix is the database UUID, unknown to the
  test); `revealInSettings(app.buttons["settings.autofill.clear-entries"])` and tap it; assert
  the confirmation appears (`app.buttons["settings.autofill.clear-entries.confirm"]`, label
  "Clear Entries"); tap "Cancel"; assert the confirm button is gone and
  `settings.autofill.clear-entries` is still present — the cancel path leaves the store
  untouched (no identity-store assertion possible from XCUITest; the clear primitive itself is
  unit-covered by slice 02's `testClearStoreEmptiesStore`). Existing `settings.autofill.*` ids
  (`link`, `turn-on`, `open-ios-settings`) are unchanged.
- *(Optional, two-surfaces-one-state)* extend the `DatabaseListUITests` case: after flipping in
  the details sheet, open Settings → AutoFill and assert the matching
  `settings.autofill.database-toggle.*` switch reads `"0"`. Skip if it makes the smoke test
  flaky — the shared-view-model wiring is already unit-pinned.

### Run commands

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseListViewModelTests \
  -only-testing:KeeForgeTests/SettingsServiceTests -quiet
```

Then, one class at a time:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/DatabaseListUITests -quiet

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/AppSettingsUITests -quiet
```

### Toolchain notes for this slice (Mac required)

- **Strings:** ten new keys in `KeeForge/Resources/Localizable.xcstrings` (app catalog only;
  extension catalogs untouched), each with a translated `de` unit: `"Include in AutoFill"`,
  the details footer (`"When off, passwords, passkeys, and verification codes …"`),
  `"Databases"`, `"No databases added yet"`,
  `"AutoFill is on, but no databases are selected."`,
  `"KeeForge suggests credentials from the databases selected below."`,
  `"Clear AutoFill Entries"`, `"Clear AutoFill Entries?"`, `"Clear Entries"`, and the
  confirmation message (`"This removes all suggestions from AutoFill. …"`). One key was
  **removed** (now-unused stale copy):
  `"KeeForge currently autofills from the last database you successfully opened."`.
  The catalog was edited as raw JSON on Linux — run `swift scripts/normalize-xcstrings.swift`
  on a Mac, re-commit any reordering diff, then
  `-only-testing:KeeForgeTests/LocalizationTests`.
- **New accessibility identifiers** (all existing ones preserved):
  `database-details.autofill-toggle`,
  `settings.autofill.database-toggle.<database-id-uuidString>`,
  `settings.autofill.clear-entries`, `settings.autofill.clear-entries.confirm`.
- **CHANGELOG:** the epic's user-facing entry was added under `## Unreleased` in this slice.
- No new files; `project.yml` untouched; `xcodegen generate` not required.

### Manual checks (device, extension enabled)

- Flip the toggle in the database-details sheet, open Settings → AutoFill: the same state shows
  there; flip it back from Settings and reopen the details sheet — both surfaces stay in sync.
- Disable a database (while it is locked): its suggestions disappear from QuickType; other
  databases' remain. Re-enable: suggestions return only after its next unlock.
- With the database open in the app, toggle off then on from **each** of the three settings
  paths — details sheet, database-list Settings sheet, and the open-database Database Settings →
  App Settings sheet (the fallback path) — and confirm suggestions reappear immediately without
  re-unlocking on all three.
- Clear AutoFill Entries → confirm: QuickType is empty (including for the currently open
  database — deliberately no republish); unlock an enabled database and watch its suggestions
  return. Cancel path leaves suggestions in place.
- Zero databases registered: Databases section shows the empty-state line. All databases
  toggled off with Quick AutoFill on: warning footer appears; turning Quick AutoFill off hides
  it.
- German (`de`): both new sections, the confirmation dialog, and the details footer render
  sensibly (long compound words must not truncate oddly).
- VoiceOver: each per-database toggle announces the database display name and on/off state;
  the details toggle announces "Include in AutoFill"; the clear button and its confirmation
  actions are reachable and the destructive action is announced as such.

---

## Slice 06: Extension database switcher

### Implementation summary (what the tests pin down)

- `CredentialProviderDatabaseSwitcherContext` (new struct in
  `AutoFillExtension/CredentialProviderCoordinator.swift`, so it compiles into `KeeForge`,
  `KeeForgeMac`, and both extension targets): `databases: [DatabaseReference]`,
  `currentDatabaseID: UUID?`, `onSwitch: (DatabaseReference, String) -> Void` — the second
  argument is the live search text at tap time.
- `CredentialProviderPresenting.presentSearchView` gained a third parameter,
  `databaseSwitcher: CredentialProviderDatabaseSwitcherContext?` (after `initialSearchText`).
  Both shells wrap `onSwitch` in their dismissal handling exactly like `onSelect`/`onCancel`
  (iOS: `dismiss(animated: false)` completion; macOS: `dismissHostedContent()` first), so by the
  time the coordinator's switch entry point runs, `isDisplayingContent` is false and the unlock
  prompt can present.
- Coordinator-internal `presentSearchView(entries:initialSearchText:includesDatabaseSwitcher:onSelect:)`:
  `includesDatabaseSwitcher: true` at the six genuine list-flow call sites (password matches +
  full list in `presentPasswordMatchesOrFinish`; passkey matches + expired-matches lists in
  `presentPasskeyMatchesOrFinish`; OTC matches + full list in `presentOTCMatchesOrFinish`);
  false (the default) for the two by-identity expired-entry confirmations
  (`completeOTCRequestFromPending`'s expired path, `completeInteractivePasskeyRequest`'s expired
  path) — those show one specific credential of one specific database and their pending request
  object was already consumed, so a switch could not re-serve them.
- Private `makeDatabaseSwitcherContext()` — the single gate: reads
  `DatabaseListStore.autoFillEnabledDatabases`; returns **nil when fewer than two are enabled**
  (the view shows the picker iff the context is non-nil), so disabled databases are never listed
  and a lone enabled database gets no switcher; `currentDatabaseID = activeDatabaseReference?.id`.
- `AutoFillSearchView` gained `databaseSwitcher: CredentialProviderDatabaseSwitcherContext? = nil`
  (defaulted init parameter — existing constructions compile unchanged). UI: toolbar `Menu` at
  `.primaryAction` labeled `"Switch Database"` (symbol `cylinder.split.1x2`), one `Button` per
  database showing `displayName`, the currently open one rendered as a checkmark `Label`.
  **Tapping the current database is a view-level no-op** (the Button action guards on
  `currentDatabaseID`), so the shells never dismiss the search view for a switch the coordinator
  would ignore.
- `switchDatabase(to:currentSearchText:)` (internal, the new entry point):
  1. Guards: `!isUnlockInProgress`, `sessionKey != nil` (a vault must currently be open — the
     switcher only exists on post-unlock search views), `activeDatabaseReference` set, and
     target id ≠ current id (same-database switch is ignored; plain return).
  2. Stashes the typed text into `pendingSwitchSearchText`.
  3. Re-validates the target against the registry (`DatabaseListStore.databases`, must still
     exist with `autoFillEnabled`): a stale target (disabled/removed by the main app since the
     switcher was built) calls `afterUnlock()` to re-present the current database's UI instead
     of dead-ending the already-dismissed shell.
  4. Sets `pendingSwitchPreviousDatabaseReference = current`, pins
     `activeDatabaseReference = target` (the fresh registry copy), resets
     `didAttemptAutoBiometricUnlock` (the new database gets its own auto-biometric attempt),
     and calls `presentUnlockPromptIfNeeded()` — the standard unlock flow, keyed to the target's
     own keychain composite key.
- **Cancel semantics: swap-on-success.** There is deliberately **no teardown at switch time**:
  the previous database's vault state — `parsedEntries`, `parsedRootGroup`, `parsedMeta`,
  `parsedFormatVersion`, `sessionKey`, `compositeKey`, `openTimeSHA512` — stays live while the
  new unlock is pending and is only overwritten wholesale by a successful `loadEntries`.
  `recordSuccessfulUnlock` is the commit point: it clears
  `pendingSwitchPreviousDatabaseReference`, re-pins, and calls `markDatabaseOpened` (updates
  `lastOpenedAt` + the active pointer through the slice-01 gated setter — the switched-to
  database becomes the session's save/passkey target via `activeDatabaseReference` and the
  next-launch default via `defaultAutoFillDatabase`). Cancelling the unlock prompt **or** the
  unlock-error alert routes through `cancelRequestOrRestoreSwitchedDatabase()`: with a switch
  pending it restores (re-pin previous reference + `afterUnlock()` re-present from the retained
  vault state, consuming the search-text stash) and does **not** cancel the request; without one
  it cancels `.userCanceled` exactly as before.
- Preserved across a switch in both directions (never touched by switching):
  `serviceIdentifiers`, `pendingPasskeyRequestParameters`, `hasPendingOTCListRequest`,
  `targetRecordIdentifier`, plus the typed search text via `pendingSwitchSearchText` (consumed
  by the next `presentSearchView`, overriding the computed initial text).
- OTC contract change: `presentOTCMatchesOrFinish()` **no longer consumes**
  `hasPendingOTCListRequest` (it stays set until a completion path runs `cleanup()`), so
  `afterUnlock()` after a switch — or an unlock retry — re-runs the OTC picker instead of
  falling through to the password list. `completeOTCRequestFromPending()`'s stale-identity
  fallback now **re-arms** `hasPendingOTCListRequest = true` (the by-identity request degrades
  into a list request) before presenting the fallback picker.
- `cleanup()` additionally clears `pendingSwitchPreviousDatabaseReference` and
  `pendingSwitchSearchText`.

### Required migrations of existing tests (compile fixes — do these first)

- `CredentialProviderCoordinatorTests.PresenterSpy.presentSearchView` must add the
  `databaseSwitcher: CredentialProviderDatabaseSwitcherContext?` parameter; extend the
  `SearchView` record struct with a `databaseSwitcher` field and store it. No existing
  assertion changes — they only touch `entries`/`initialSearchText`/`onSelect`/`onCancel`.
- Recommended: extend `assertCleanedUp` with
  `XCTAssertNil(coordinator.pendingSwitchPreviousDatabaseReference)` and
  `XCTAssertNil(coordinator.pendingSwitchSearchText)`.
- The existing `test_otcList_*` cases stay green despite the flag-retention change: they assert
  `hasPendingOTCListRequest` only via `assertCleanedUp` **after** a completion path already ran
  `cleanup()` (which still clears it). The prepare-time assertion at
  `test_otcList_singleMatch_completesWithCode` (flag true after prepare) is unaffected.
- `CredentialProviderShellMacTests` compiles unchanged (no presenter conformance there; the
  production shell was updated in this slice).

### Seams to use

- `presenter.searchView.databaseSwitcher` — the spy-recorded context is the main seam: inspect
  `databases`/`currentDatabaseID`, and invoke `onSwitch(reference, "typed text")` to simulate a
  tap. `PresenterSpy.isDisplayingContent` defaults to false, which matches the production
  precondition (the shell dismisses the search view before forwarding the switch).
- Registry seeding as in slices 01/03: `TestDatabaseSupport.makeReference(for:lastOpenedAt:)`
  (+ the `autoFillEnabled:` builder parameter documented in slice 01),
  `DatabaseListStore.update(_:)` / `markDatabaseOpened(id:at:)` /
  `setAutoFillEnabled(_:for:)` / `clearAll()` in setUp/tearDown.
- Vault seeding: the existing `seedUnlockedVaultState(_:entries:sessionKey:)` helper **plus a
  direct `coordinator.activeDatabaseReference = referenceA` write** — `switchDatabase` guards on
  both `sessionKey` and the pin.
- Real unlock of the switched-to database: write the `TestFixtures/test.kdbx` fixture bytes
  (password `testpassword123`) to `DatabaseListStore.cacheLocation(for: targetReference)`, then
  drive `presenter.unlockPrompt.onSubmitPassword("testpassword123")`. The unlock task is async —
  add a spy hook `onSearchViewPresented: (() -> Void)?` (mirroring the existing
  `onUnlockErrorPresented`) fired from `presentSearchView`, and await it with an expectation.
- `BiometricService.isAvailable` is false under simulator tests, so a switch always lands on the
  password prompt; the biometric-cancel-mid-switch path is covered indirectly (biometric cancel
  throws into `showErrorAndRetry`, the same error-alert path tested below) plus manually.

### `KeeForgeTests/CredentialProviderCoordinatorTests.swift` (new cases)

Switcher presence and source list:

- `test_searchView_carriesSwitcherWithTwoEnabledDatabases` — register enabled A and B, pin A
  (`activeDatabaseReference = A`), seed vault, `presentPasswordMatchesOrFinish()`:
  `searchView.databaseSwitcher` is non-nil, its `databases` ids are exactly `[A.id, B.id]`, and
  `currentDatabaseID == A.id` (checkmark contract).
- `test_searchView_omitsSwitcherWithSingleEnabledDatabase` — only A registered: presented
  `searchView.databaseSwitcher == nil` (picker hidden below two enabled databases).
- `test_searchView_switcherNeverListsDisabledDatabases` — A and C enabled, B registered with
  `autoFillEnabled == false`: listed ids are exactly `{A.id, C.id}`; then
  `setAutoFillEnabled(false, for: C)` and re-present: switcher is nil (only one enabled left).
  *(The spec's "disabled databases never appear in the switcher's source list".)*
- `test_byIdentityExpiredConfirmations_carryNoSwitcher` (`@available(iOS 18.0, *)` for the OTC
  half) — with two enabled databases registered, drive `completeOTCRequestFromPending()` with an
  expired matching TOTP target (and/or `completeInteractivePasskeyRequest` with an expired
  passkey entry): the presented confirmation's `databaseSwitcher` is nil.

Switch flow (spec: "switch to another enabled database triggers its unlock flow and retargets
search/save/passkey registration"):

- `test_switch_presentsUnlockPromptPinnedToTargetAndRetainsPreviousVault` — from the two-database
  search, invoke `databaseSwitcher.onSwitch(B, "typed")`: `presenter.unlockPrompt` is presented,
  `activeDatabaseReference?.id == B.id`, `pendingSwitchPreviousDatabaseReference?.id == A.id`,
  `pendingSwitchSearchText == "typed"`, and the previous vault is untouched (`sessionKey`
  non-nil, `parsedEntries` unchanged) — the unlock/biometric/key pipeline now targets B while
  A remains restorable.
- `test_switch_toCurrentDatabaseIsIgnored` — `coordinator.switchDatabase(to: A)` while A is
  open: no unlock prompt, no stash, all state untouched (production additionally filters this at
  the view level so the shell never dismisses for it).
- `test_switch_toDatabaseDisabledSinceListingRepresentsCurrentSearch` — build the search with A
  and B enabled, then `setAutoFillEnabled(false, for: B)` **before** invoking `onSwitch(B, "")`:
  no unlock prompt, `activeDatabaseReference` still A, no stash, and the search view is
  presented again (the coordinator re-presents instead of dead-ending the dismissed shell) —
  the "database disabled in the app between extension launches" edge.
- `test_switchUnlockSuccess_retargetsSessionAndDefault` — seed the cache for B with fixture
  bytes; switch with typed text; submit the fixture password; await `onSearchViewPresented`:
  the re-presented `searchView.entries` are B's parsed entries, `initialSearchText` equals the
  preserved typed text, `activeDatabaseReference?.id == B.id`,
  `pendingSwitchPreviousDatabaseReference` is nil (switch committed),
  `DatabaseListStore.activeAutoFillDatabaseID == B.id`, B's `lastOpenedAt` was updated, and
  `DatabaseListStore.defaultAutoFillDatabase?.id == B.id`. The last three pin the retarget
  contract: in-session save/passkey registration read `activeDatabaseReference` (see
  `saveNewEntry`), and the next extension launch's identifier-less flows resolve
  `defaultAutoFillDatabase` — both now point at B.
- `test_switchDuringOTCList_reRunsOTCPickerAfterUnlock` (`@available(iOS 18.0, *)`) —
  `prepareOneTimeCodeCredentialList`, seed a TOTP vault for A, `presentOTCMatchesOrFinish()`
  (multi-match picker), switch to B, then cancel the unlock: the re-presented picker contains
  TOTP entries again (not the password list) and `hasPendingOTCListRequest` is still true —
  pins the flag-retention change.
- `test_otcStaleFallback_reArmsListFlag` (`@available(iOS 18.0, *)`) — drive
  `completeOTCRequestFromPending()` with a stale `targetRecordIdentifier` and ≥2 TOTP entries:
  the fallback picker is presented and `hasPendingOTCListRequest == true` (by-identity request
  converted to a list request so a subsequent switch re-serves it).
- *(Optional)* passkey-parameters retarget: `pendingPasskeyRequestParameters` survives a switch
  by construction (it is never consumed by presentation), but
  `ASPasskeyCredentialRequestParameters` has no public initializer that could be verified in
  this environment — check on a Mac whether it is test-constructible; if not, the OTC and
  password cases above cover the shared `afterUnlock` dispatch, and the field's preservation is
  implicitly pinned by `test_switchCancel_restoresPreviousDatabaseAndRepresentsSearch` below
  (which asserts the request context is untouched). Document the gap inline if skipped.

Cancel semantics (spec: "cancelling the switch unlock leaves the previous database active" —
implemented as **swap-on-success**, so "active" means: still pinned, still unlocked in memory,
its search re-presented; the request is NOT cancelled):

- `test_switchCancel_restoresPreviousDatabaseAndRepresentsSearch` — after
  `test_switch_presentsUnlockPromptPinnedToTargetAndRetainsPreviousVault`'s setup, invoke
  `unlockPrompt.onCancel()`: `presenter.cancelledError` stays nil, `activeDatabaseReference?.id
  == A.id`, `pendingSwitchPreviousDatabaseReference` is nil, the search view is re-presented
  from A's retained entries with `initialSearchText == "typed"` (stash consumed), and selecting
  an entry from it still completes the request with A's credential (A's `sessionKey` was never
  torn down).
- `test_switchUnlockErrorCancel_restoresPreviousDatabase` — switch A→B with no cached bytes for
  B, `unlockPrompt.onSubmitPassword("wrong")`, await `onUnlockErrorPresented`, invoke
  `unlockError.onCancel()`: same restoration assertions as above. This is also the
  biometric-cancel-mid-switch shape: a cancelled biometric prompt throws into the same
  `showErrorAndRetry` → error-alert → Cancel path.
- `test_switchUnlockErrorRetry_staysPinnedToTarget` — same setup, invoke `unlockError.onRetry()`:
  the unlock prompt is presented again and `activeDatabaseReference?.id == B.id` (the retry loop
  keeps targeting the switched-to database; only Cancel restores).

### Run command

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/CredentialProviderCoordinatorTests -quiet
```

### Toolchain notes for this slice (Mac required)

- **Strings:** one new key in `AutoFillExtension/Localizable.xcstrings` (both extension
  targets; `InfoPlist.xcstrings` untouched): `"Switch Database"` with `de` unit
  `"Datenbank wechseln"`, inserted by hand between `"Show %@"` and `"System Default"`. Run
  `swift scripts/normalize-xcstrings.swift` on a Mac, re-commit any reordering diff, then
  `-only-testing:KeeForgeTests/LocalizationTests`. Database display names in the menu are user
  data (not localized); the checkmark row reuses no new strings.
- **New accessibility identifiers** (all existing search-view ids preserved):
  `autofill.database-switcher` on the toolbar menu control, and
  `autofill.database-switcher.<database-id-uuidString>` on each row (uppercase UUID, matching
  slice 05's `settings.autofill.database-toggle.<uuid>` per-row convention).
- **CHANGELOG:** `- Switch between databases inside the AutoFill panel.` added under
  `## Unreleased` in this slice.
- No new files; `project.yml` untouched; `xcodegen generate` not required.

### Manual checks (device + mac extension; requires ≥2 databases enabled)

- Personal (default) and Work both enabled: invoke AutoFill manually on a Work-only site, open
  the toolbar switcher (Personal is checkmarked), pick Work → Work's biometric/password unlock →
  the search re-appears with Work's entries and the previously typed search text → fill
  completes.
- Save a new credential while switched (a subsequent iOS save-password request): it lands in
  Work; relaunch AutoFill manually and confirm Work is now the default database.
- Cancel the switch unlock via the password prompt's Cancel: Personal's search returns, with
  entries and search text intact; selecting an entry still fills (no re-unlock needed).
- Biometric cancel mid-switch (Face ID device, auto-unlock enabled): switching auto-triggers
  Face ID for Work; cancel it → error alert → Cancel → Personal's search returns; Try Again →
  Face ID again for Work.
- Switch to a cloud (cache-only) database: unlock parses the App Group cached copy without
  touching the bookmark; switch succeeds offline.
- Disable Work in the main app, return to the extension (or relaunch): the switcher no longer
  lists Work; with only one database left enabled, the switcher control disappears entirely.
- With exactly one enabled database from the start: no switcher control in the search toolbar.
- OTC flow: invoke the code picker with both databases enabled, switch to a database with no
  TOTP entries — accepted behavior is the standard flow's: the request ends with
  "not found" (same as if that database had been the default). Verify no crash/dead UI.
- German (`de`): the menu control announces/labels "Datenbank wechseln"; VoiceOver reads each
  row's database name and the checkmark state on the current one.
