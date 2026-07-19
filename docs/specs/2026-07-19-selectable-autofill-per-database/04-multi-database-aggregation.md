# Slice 04: Multi-Database Aggregation and Targeted Removal

> Parent: [`epic.md`](./epic.md) · Depends on: 02, 03

## Goal

Flip publication from whole-store replace to per-database refresh, so QuickType simultaneously offers every enabled database's entries and each lifecycle event touches only the affected database's identities.

## Scope

**In:**

- Per-database refresh in `CredentialIdentityStoreManager`: enumerate the store; remove identities owned by the refreshing database plus any legacy-format identities; save the database's current identity set. When enumeration shows no other database's identities, an atomic full replace is an acceptable equivalent. This refresh runs on every path that populates today: main-app unlock, edit/save refreshes, and in-extension save.
- Wire targeted removal into lifecycle events:
  - Per-database toggle **off** → remove exactly that database's identities (works while locked; replaces slice 01's interim clear-store) and fix the active pointer per slice 01's rules.
  - Per-database toggle **on** → lazy by default; if that database is currently unlocked in the main app, refresh it immediately.
  - Database removed from the registry → remove its identities even when it was not active (fixes the current gap where only the active database's removal clears anything).
  - Global Quick AutoFill **off** → `clearStore` (unchanged). Global **on** → immediately refresh any currently unlocked enabled database; everything else repopulates on next unlock.
- Expired-entry filtering and dedup keep working per database within the new refresh.
- Because every refresh removes the database's own stale identities before saving, deleted entries can never linger past their database's next refresh — no Strongbox-style periodic full clear is added.
- Document (code-comment level) the accepted cross-process race: app and extension may interleave enumerate/mutate; worst case is a briefly stale or duplicate suggestion corrected by the next refresh.

**Out:**

- UI for the toggles and the clear button (slice 05).
- Any change to which flows the extension offers (done in 03).

## Affected areas

- Modified: `KeeForge/Services/AutoFill/CredentialIdentityStoreManager.swift`, `KeeForge/ViewModels/DatabaseViewModel.swift`, `KeeForge/Services/AutoFill/AutoFillSaveCoordinator.swift`, `KeeForge/Services/Persistence/DatabaseListStore.swift` (removal hook on database delete), `KeeForge/ViewModels/DatabaseListViewModel.swift` (toggle-off/on wiring), `KeeForge/Views/SettingsView.swift` (global-toggle handlers now refresh instead of blanket populate).

## KeeForge bits

- **Targets:** all touched services are already in both extension allow-lists; view models and `SettingsView` are app-only. Keep shared files extension-safe.
- **project.yml:** No changes. `xcodegen generate` not required unless files are added.
- **Accessibility identifiers:** N/A — no view-layer additions (SettingsView handler changes only).
- **CHANGELOG:** deferred to the epic's entry.

## Testing

- **Unit:** `CredentialIdentityStoreManagerTests.swift` (fake store) — refresh of database A then B yields the union; re-refresh of A after an entry deletion removes only that entry's identities and leaves B intact; refresh purges legacy-format identities; toggle-off removal leaves B untouched; database-removal removal works with everything locked (no entries available — pure enumeration); store-disabled state no-ops every operation.
  `DatabaseViewModelTests.swift` — via observers: unlock refreshes only the unlocked database; global toggle on refreshes the currently unlocked enabled database and nothing else; toggle-on of the open database refreshes immediately; toggle-off of a background database triggers removal, not clear.
  `DatabaseListStoreTests.swift` — removing a non-active database triggers its identity removal hook.
  Run slice: `-only-testing:KeeForgeTests/CredentialIdentityStoreManagerTests -only-testing:KeeForgeTests/DatabaseViewModelTests -only-testing:KeeForgeTests/DatabaseListStoreTests`
- **Integration / UI:** N/A — aggregate behavior is asserted through the fake store; device behavior covered manually.
- **Manual:** unlock Personal, then Work; confirm QuickType shows entries from both and each fills via its owner (slice 03); delete an entry from Work, save, confirm only that suggestion disappears; disable Work while locked and confirm its suggestions vanish while Personal's remain; remove Work from the app and confirm the same.
- **Edge cases that apply:** all databases locked during removal, store cleared externally between enumerate and mutate, in-extension save racing a main-app refresh, background→foreground refresh paths.

## Exit criteria

- [ ] Unit tests above pass.
- [ ] Manual multi-database checks done.
- [ ] Slice 01's interim clear-on-disable is fully replaced by targeted removal.
- [ ] No force unwraps; store work off main; no secret logging.
- [ ] CHANGELOG explicitly deferred to the epic's entry.

## CHANGELOG entry

N/A — covered by the epic's entry, lands with slice 05.
