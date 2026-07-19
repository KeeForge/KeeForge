# Slice 03: Extension Identity-to-Database Resolution

> Parent: [`epic.md`](./epic.md) · Depends on: 02

## Goal

The AutoFill extension resolves a tapped QuickType suggestion to the database that owns it and unlocks *that* database — instead of assuming everything lives in the single active database — and treats disabled databases as nonexistent across all its flows.

## Scope

**In:**

- `CredentialProviderCoordinator` resolution: parse the record identifier; current format → look up the owning `DatabaseReference` in `DatabaseListStore`; legacy format → the active database as today. Then load that reference's cached copy (bookmark fallback for local files, cache-only for cloud, exactly as the active-database path does today) and unlock it — biometric via that database's own keychain composite key, or its password prompt — and find the entry by UUID.
- Disabled-database enforcement (the toggle governs the whole surface):
  - A resolved reference with AutoFill disabled is treated as stale (below), not unlocked.
  - Manual search, in-extension save, and passkey registration operate on the *default* database: the active pointer if it resolves to an enabled database, else the most recently opened enabled database, else none.
  - With zero enabled databases, all flows land on a localized empty state telling the user to enable a database in KeeForge's settings; the save/registration UIs are unavailable rather than failing.
- Stale-suggestion handling (better than KeePassium's wipe-all): identifier unparseable, database unknown/disabled, or entry missing after unlock → remove the offending identities (the single identity for a missing entry; the database's identities for an unknown/disabled database; legacy identifiers may fall back to `clearStore` since they are unattributable) → then fall back to interactive search on the default database or the empty state. Never a silent dead tap.
- Passkey assertion and one-time-code requests follow the same resolution path as passwords.
- Biometric availability (`canUseBiometrics`) is evaluated against the resolved database, not blindly against the active one.

**Out:**

- Publication changes — the store still holds one database's identities until slice 04; this slice just stops *assuming* it does.
- A database switcher in the manual search UI (slice 06).
- Main-app UI (slice 05).

## Affected areas

- Modified: `AutoFillExtension/CredentialProviderCoordinator.swift`, possibly `AutoFillExtension/AutoFillSearchView.swift` / `AutoFillEntryCreatorView.swift` (empty-state and disabled-save presentation), `AutoFillExtension/*.xcstrings` (new strings), `KeeForge/Services/AutoFill/AutoFillSaveCoordinator.swift` (default-database selection shared with save).

## KeeForge bits

- **Targets:** coordinator and AutoFill views compile into `KeeForgeAutoFill`, `KeeForgeMacAutoFill`, and (coordinator only) `KeeForge` for test hosting. Coordinator stays UIKit/AppKit-free per `AutoFillExtension/README.md`; new presentation goes through `CredentialProviderPresenting`.
- **project.yml:** No changes expected; if any new shared file appears, add to both order-locked allow-lists and run `xcodegen generate`.
- **Accessibility identifiers:** new ids for the empty state (e.g. an `autofill.no-enabled-databases` label/action following existing extension conventions); all existing search/creator ids preserved.
- **CHANGELOG:** deferred to the epic's entry.

## Testing

- **Unit:** `CredentialProviderCoordinatorTests.swift` — resolution picks the owning database when it differs from the active one (unlock prompt/biometric path targets the owner); legacy identifier resolves to the active database; unknown database id triggers stale cleanup and interactive fallback; resolved-but-disabled database likewise; missing entry after unlock removes that identity and falls back; default-database selection order (enabled active → most recent enabled → none); zero-enabled-databases produces the empty state and blocks save; passkey assertion resolves through the same path.
  `CredentialProviderSaveTests.swift` — save targets the default *enabled* database; save unavailable with zero enabled.
  Run slice: `-only-testing:KeeForgeTests/CredentialProviderCoordinatorTests -only-testing:KeeForgeTests/CredentialProviderSaveTests`
- **Integration / UI:** N/A — extension flows are covered by the hosted coordinator tests; no XCUITest drives the system AutoFill panel.
- **Manual:** with two databases set up: tap a QuickType suggestion for the non-active database and complete a biometric unlock + fill; disable the only database and invoke AutoFill manually to see the empty state; tap a suggestion whose database was removed from the app and confirm graceful fallback plus the suggestion's disappearance.
- **Edge cases that apply:** locked owning database (unlock prompt, `userInteractionRequired` path), cloud database with cache-only access, biometric-cancel falling back to password, extension launched with store recently cleared by the system.

## Exit criteria

- [ ] Unit tests above pass.
- [ ] Manual checks done on iOS; mac extension smoke-checked.
- [ ] New extension strings exist in `en` and `de` in both extension catalogs; `LocalizationTests` green; `swift scripts/normalize-xcstrings.swift` run.
- [ ] No force unwraps; coordinator remains platform-framework-free; secrets only via keychain/`EncryptedValue` paths.
- [ ] CHANGELOG explicitly deferred to the epic's entry.

## CHANGELOG entry

N/A — covered by the epic's entry, lands with slice 05.
