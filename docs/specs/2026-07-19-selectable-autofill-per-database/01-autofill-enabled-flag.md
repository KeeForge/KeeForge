# Slice 01: AutoFill-Enabled Flag and Publication Gating

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

Add a persisted per-database `autoFillEnabled` flag and enforce, inside today's single-active-database behavior, that a disabled database never publishes credential identities and never becomes the active AutoFill database.

## Scope

**In:**

- New boolean on `DatabaseReference`, default enabled, following the hand-written `Codable` pattern (`CodingKeys` + `decodeIfPresent ?? true`) so existing `database-list.json` files decode as enabled.
- `DatabaseListStore`: a mutation helper to set the flag (modeled on `setReadOnly(_:for:)`), an accessor for "databases with AutoFill enabled", and gating of every write path to `activeAutoFillDatabaseID` — `markDatabaseOpened(id:)`, the AutoFill-save path, and the legacy `fallbackAutoFillDatabase` resolution — so a disabled database can never be, or become, active.
- `DatabaseViewModel.populateCredentialStoreIfNeeded` (and its refresh callers): skip both the active-pointer write and the identity-store populate when the database is disabled. The previously active database's identities stay in the store untouched.
- `AutoFillSaveCoordinator`: same gating on its populate/active-pointer writes (defensive; slice 03 makes a disabled database unreachable in the extension).
- Disabling the database that is currently active: clear the store (coarse interim behavior — slice 04 replaces this with targeted removal) and reassign or clear the active pointer.
- `DatabaseListViewModel`: a setter helper following the `setReadOnly` / private-`update` pattern, ready for slice 05's UI.
- Do **not** copy `isQuickLaunch`'s mutual-exclusion sweep in `normalized(...)` — this flag is independently multi-valued.

**Out:**

- Any UI (slice 05).
- Record-identifier changes, store enumeration, targeted removal (slices 02/04).
- Extension behavior changes beyond the shared gating above (slice 03).

## Affected areas

- Modified: `KeeForge/Models/DatabaseReference.swift`, `KeeForge/Services/Persistence/DatabaseListStore.swift`, `KeeForge/ViewModels/DatabaseViewModel.swift`, `KeeForge/ViewModels/DatabaseListViewModel.swift`, `KeeForge/Services/AutoFill/AutoFillSaveCoordinator.swift`.

## KeeForge bits

- **Targets:** all modified files are already shared — `DatabaseReference` (via `KeeForge/Models`), `DatabaseListStore`, and `AutoFillSaveCoordinator` compile into `KeeForge`, `KeeForgeAutoFill`, and `KeeForgeMacAutoFill`; keep them extension-safe. The view models are app-targets only.
- **project.yml:** No changes. Run `xcodegen generate` only if a file is added after all.
- **Accessibility identifiers:** N/A — no view-layer work.
- **CHANGELOG:** deferred to the epic's entry (lands with slice 05).

## Testing

- **Unit:** `DatabaseReferenceTests.swift` — round-trip of the new flag both ways; decoding JSON without the key yields enabled (the migration guarantee); `DatabaseReferenceMigrationTests.swift` confirms legacy single-database migration produces enabled references.
  `DatabaseListStoreTests.swift` — setter persists across reload; `activeAutoFillDatabaseID` refuses a disabled database's id; `markDatabaseOpened` on a disabled database leaves the previous active id in place; disabling the active database clears/reassigns the pointer; the legacy fallback never returns a disabled database.
  `DatabaseViewModelTests.swift` — via the `#if DEBUG` `populateObserver`/`clearObserver` seams: unlocking a disabled database triggers no populate and no active-pointer change; unlocking an enabled one behaves as today; edit/save refresh paths on a disabled database stay silent.
  `CredentialProviderSaveTests.swift` — extension save flow does not set a disabled database active.
  Run slice: `-only-testing:KeeForgeTests/DatabaseReferenceTests -only-testing:KeeForgeTests/DatabaseListStoreTests -only-testing:KeeForgeTests/DatabaseViewModelTests -only-testing:KeeForgeTests/CredentialProviderSaveTests`
- **Integration / UI:** N/A — no user-reachable surface yet; the flag is only settable programmatically until slice 05.
- **Manual:** none required this slice (unreachable without UI); rely on unit coverage.
- **Edge cases that apply:** locked database (flag flips must not require unlock — they don't, registry-only), background→foreground (store reloads keep the flag), decode of pre-feature `database-list.json`.

## Exit criteria

- [ ] Unit tests above pass.
- [ ] Existing `database-list.json` files decode with every database AutoFill-enabled.
- [ ] `AppGroupGuardrailTests` still green (new field is a plain bool in the existing registry file).
- [ ] No force unwraps; no main-thread crypto/parsing introduced.
- [ ] CHANGELOG explicitly deferred to the epic's entry.

## CHANGELOG entry

N/A — covered by the epic's entry, lands with slice 05.
