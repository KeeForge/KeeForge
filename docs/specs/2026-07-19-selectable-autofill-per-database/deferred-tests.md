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
  `clearObserver: (() -> Void)?` (unchanged), **new** `removeDatabaseObserver: ((UUID) -> Void)?`
  (fires on `removeIdentities(forDatabase:)`), and **new**
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
  targeted removal (the seam slice 04's `DatabaseListStore` tests will rely on).

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

_To be filled by the slice 03 implementation._

---

## Slice 04: Multi-database aggregation and targeted removal

_To be filled by the slice 04 implementation._

---

## Slice 05: Settings UI and Clear AutoFill Entries

_To be filled by the slice 05 implementation._

---

## Slice 06: Extension database switcher

_To be filled by the slice 06 implementation._
