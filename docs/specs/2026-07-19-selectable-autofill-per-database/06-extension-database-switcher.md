# Slice 06: Extension Database Switcher *(optional)*

> Parent: [`epic.md`](./epic.md) · Depends on: 03

## Goal

Let the user switch between enabled databases inside the extension's manual search UI, closing the gap where a credential lives in an enabled database that is not the current default.

## Scope

**In:**

- A database picker in `AutoFillSearchView` (menu or equivalent lightweight control) listing enabled databases only, shown only when two or more are enabled. Selecting one runs the standard unlock flow for that database (biometric with its composite key, or password) and re-runs the current search against it.
- The chosen database becomes the session's target for save and passkey registration, and is recorded as most-recently-opened (which updates the default for next launch through the existing active-pointer rules).
- Localized strings (`en` + `de`) in both extension catalogs.

**Out:**

- Cross-database merged search results (one database at a time in the manual UI; QuickType is the cross-database surface).
- Any main-app UI, and any behavior with zero or one enabled database (already covered by slices 03/05).

## Affected areas

- Modified: `AutoFillExtension/AutoFillSearchView.swift`, `AutoFillExtension/CredentialProviderCoordinator.swift` (switch entry point on top of slice 03's open-any-enabled-database machinery), extension `.xcstrings` catalogs.

## KeeForge bits

- **Targets:** both extension targets; coordinator changes also compile into `KeeForge` for test hosting. Coordinator stays platform-framework-free.
- **project.yml:** No changes. `xcodegen generate` not required.
- **Accessibility identifiers:** new picker id following extension conventions (e.g. `autofill.database-switcher`) plus stable per-database row ids; existing search-view ids preserved.
- **CHANGELOG:** own entry (user-visible, ships after the epic's main entry).

## Testing

- **Unit:** `CredentialProviderCoordinatorTests.swift` — switch to another enabled database triggers its unlock flow and retargets search/save/passkey registration; disabled databases never appear in the switcher's source list; cancelling the switch unlock leaves the previous database active.
  Run slice: `-only-testing:KeeForgeTests/CredentialProviderCoordinatorTests`
- **Integration / UI:** N/A — system AutoFill UI is not driven by XCUITest; hosted coordinator tests plus manual coverage.
- **Manual:** with Personal (default) and Work enabled: invoke AutoFill manually on a Work-only site, switch to Work, unlock, fill; save a new credential while switched and verify it lands in Work; relaunch AutoFill and confirm Work is now the default.
- **Edge cases that apply:** biometric cancel mid-switch, switching to a cloud (cache-only) database, database disabled in the app between extension launches.

## Exit criteria

- [ ] Unit tests above pass.
- [ ] Manual switch/save/default checks done.
- [ ] Extension strings in `en` + `de`; `LocalizationTests` green; normalize script run.
- [ ] No force unwraps; coordinator remains UIKit/AppKit-free.
- [ ] CHANGELOG entry added under `## Unreleased`.

## CHANGELOG entry

`- Switch between databases inside the AutoFill panel.`
