# Slice 05: Settings UI and Clear AutoFill Entries

> Parent: [`epic.md`](./epic.md) · Depends on: 01, 02, 04

## Goal

Give users the controls: a per-database AutoFill toggle in the database detail sheet, a databases overview inside AutoFill settings, and a confirmed "Clear AutoFill Entries" action.

## Scope

**In:**

- `DatabaseDetailsView` (in `DatabaseListView.swift`): a new "AutoFill" section with a toggle bound through `DatabaseListViewModel`'s slice-01 setter, mirroring the existing Read-Only section's idiom. Footer copy must state the full scope: passwords, passkeys, and verification codes from this database are neither suggested nor available in AutoFill while off; and that after re-enabling, suggestions return the next time the database is unlocked.
- `AutoFillSettingsView` (in `SettingsView.swift`):
  - A "Databases" section listing every registered database with the same toggle (two surfaces, one state — changes reflect immediately in both), so the feature is discoverable without opening each detail sheet. Rows show the database display name; each row's toggle gets a stable per-database accessibility identifier.
  - A footer warning when Quick AutoFill is globally on but zero databases are enabled ("AutoFill is on but no databases are selected").
  - A destructive "Clear AutoFill Entries" button behind a confirmation dialog. Confirming calls the slice-02 clear primitive; copy explains that suggestions rebuild as enabled databases are next unlocked — deliberately no immediate republish of the currently open database (respect the user's intent to empty the store now).
- Toggle changes drive the slice-04 behavior (targeted removal on off, immediate refresh when the toggled database is currently unlocked, lazy otherwise).
- All new strings in `en` and `de` in the app's `Localizable.xcstrings`; run the normalize script.

**Out:**

- Extension-side UI (slices 03/06 own extension strings and states).
- Any new per-entry controls, display-format options, or re-ordering of existing settings.

## Affected areas

- Modified: `KeeForge/Views/DatabaseListView.swift` (`DatabaseDetailsView`), `KeeForge/Views/SettingsView.swift` (`AutoFillSettingsView`), `KeeForge/ViewModels/DatabaseListViewModel.swift` (if the slice-01 setter needs surfacing), `KeeForge/Resources/Localizable.xcstrings`.

## KeeForge bits

- **Targets:** views and view models are app-targets only (`KeeForge`, mac app if the shared SwiftUI files compile there — follow the existing membership of the touched files).
- **project.yml:** No changes. `xcodegen generate` not required.
- **Accessibility identifiers:** new — `database-details.autofill-toggle`; per-row toggles in AutoFill settings using a stable per-database form (e.g. `settings.autofill.database-toggle` suffixed with the database id, consistent with how existing per-row ids are built); `settings.autofill.clear-entries` and an id for the confirmation's destructive action. All existing `database-details.*`, `database-row.*`, and `settings.autofill.*` ids preserved.
- **CHANGELOG:** this slice adds the epic's user-facing entry under `## Unreleased`.

## Testing

- **Unit:** `DatabaseListViewModelTests.swift` (or the existing home of `setReadOnly` coverage) — toggling through the view model persists and fires the slice-04 side effects (assert via the store-manager observers).
  `SettingsServiceTests.swift` — unchanged global-toggle semantics still covered.
  Run slice: `-only-testing:KeeForgeTests/DatabaseListViewModelTests`
- **Integration / UI:** update the XCUITest that covers the database-details sheet to flip the new toggle and assert persistence across reopen; add a settings-flow assertion that the clear button presents its confirmation and can be cancelled. Keep to the smallest relevant UI test file per `KeeForgeUITests/README.md`; do not run the full UI suite.
- **Manual:** flip the toggle in the detail sheet and see the same state in AutoFill settings; disable a database and watch its suggestions disappear from QuickType; clear entries, confirm QuickType is empty, unlock a database and watch suggestions return; check `de` renders sensibly in both new sections.
- **Edge cases that apply:** zero databases registered (Databases section empty state), zero enabled (warning footer), toggling while the database is locked (allowed; removal immediate, publication lazy), VoiceOver labels on the new controls.

## Exit criteria

- [ ] Unit + targeted UI tests pass.
- [ ] Manual checks done, including German.
- [ ] `LocalizationTests` green; `swift scripts/normalize-xcstrings.swift` run after catalog edits.
- [ ] Existing accessibility identifiers untouched; new ones documented in the UI-test update.
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG entry

`- Choose which databases appear in AutoFill, get suggestions from all of them at once, and clear AutoFill suggestions in Settings.`
