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
- `AutoFillSaveCoordinator.Environment` with the existing private `SaveRecorder` +
  `makeEnvironment(recorder:)` helpers in `CredentialProviderSaveTests` (its `populateCredentialStore` closure is
  the populate seam; no real identity store is touched).
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

_To be filled by the slice 02 implementation._

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
