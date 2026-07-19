# Epic: Selectable AutoFill Per Database

## Summary

Let users choose, per database, whether that database participates in iOS/macOS AutoFill. Today KeeForge is single-active-database: every unlock replaces the entire system credential identity store with the just-unlocked database's entries, identities carry no database attribution, and the extension can only ever open the one "active" database. This epic adds a per-database AutoFill toggle, database-tagged credential identities, multi-database QuickType aggregation, targeted (per-database) identity removal, and a user-facing "Clear AutoFill Entries" action.

## Clarified requirements

> The interactive clarification round could not be delivered (unattended session), so these are
> spec-author decisions with rationale, modeled on the competitor findings below. Each is
> revisable in review; the slice split isolates the blast radius of flipping any of them.

- **Q: Aggregate QuickType across enabled databases, or keep the single-active model?**
  **A (decided):** Aggregate. Suggestions from all enabled databases coexist; tapping one makes the extension unlock the owning database. This matches both comparables and is what "selectable per database" implies; the per-database cache and per-database keychain composite keys already exist, so only identity attribution and extension resolution are missing. The slices are ordered so the single-active behavior remains intact until the final aggregation slice flips on (04) — stopping after slice 03 still yields a coherent, shippable "toggle gates the single active database" feature if aggregation is deferred.
- **Q: Does disabling AutoFill for a database affect only QuickType suggestions, or the whole AutoFill surface?**
  **A (decided):** The whole surface (Strongbox's `autoFillEnabled` model): no QuickType suggestions, and the extension will not offer, unlock, or save into a disabled database. One toggle, one mental model: "this database never appears in AutoFill." Documented consequence: passkeys stored in a disabled database cannot be used through AutoFill at all; the toggle's UI copy must say so.
- **Q: Default state for existing and new databases?**
  **A (decided):** Enabled, via `decodeIfPresent ?? true` on the persisted registry — updating the app changes nothing for existing users, and newly added databases participate immediately (KeeForge's current implicit behavior). Strongbox's per-database opt-in was rejected because KeeForge already ships AutoFill-on-by-default and regressing that would break users.
- **Q: Is there a "Clear AutoFill Entries" action, and at what granularity?**
  **A (decided):** Yes — one global destructive button in AutoFill settings, behind a confirmation dialog. It empties the credential identity store; suggestions rebuild lazily on the next unlock/save of each enabled database. No per-database clear button: toggling a database off already removes exactly that database's identities (targeted removal, below), which covers the per-database case with better semantics. Neither comparable ships a clear button; KeeForge adds one because aggregation makes "what is in QuickType right now" less obvious and a one-tap reset is cheap insurance against stale state.

## Competitor and reference findings

- [KeePassium](https://github.com/keepassium/KeePassium) has a per-database "Quick AutoFill" switch that only opts *down* from a global setting (effective = per-DB AND global, nil per-DB inherits global) — [`DatabaseSettingsManager.swift`](https://github.com/keepassium/KeePassium/blob/master/KeePassiumLib/KeePassiumLib/util/db-settings/DatabaseSettingsManager.swift). Its record identifier is a versioned colon-joined string `version:fileProvider:fileDescriptor:entryUUID` — [`QuickTypeAutoFillRecord.swift`](https://github.com/keepassium/KeePassium/blob/master/KeePassiumLib/KeePassiumLib/util/autofill/QuickTypeAutoFillRecord.swift) — so per-database attribution exists, yet every disable/removal event calls `removeAllCredentialIdentities` and relies on other databases lazily repopulating on next unlock ([`QuickTypeAutoFillStorage.swift`](https://github.com/keepassium/KeePassium/blob/master/KeePassiumLib/KeePassiumLib/util/autofill/QuickTypeAutoFillStorage.swift)). With ≥2 QuickType databases it switches from `replaceCredentialIdentities` to additive `saveCredentialIdentities`, accepting that deleted entries linger as stale suggestions until tapped. A stale tap purges the whole store and falls back to the interactive UI. No clear button, no identity-count handling.
- [Strongbox](https://github.com/strongbox-password-safe/Strongbox) layers per-database `autoFillEnabled` (gates the whole surface — a disabled database is not even offered in the extension) over `quickTypeEnabled` (gates suggestion publication) — [`SafeMetaData.h`](https://github.com/strongbox-password-safe/Strongbox/blob/master/StrongBox/SafeMetaData.h). Its record identifier is a JSON blob `{safeId, nodeId, fieldKey}` — [`QuickTypeRecordIdentifier.m`](https://github.com/strongbox-password-safe/Strongbox/blob/master/StrongBox%20Auto%20Fill/QuickTypeRecordIdentifier.m). Same coarse removal: any per-database disable wipes the entire store ([`AutoFillManager.m`](https://github.com/strongbox-password-safe/Strongbox/blob/master/macbox/AutoFillManager.m)), with an alert telling the user to reopen their other databases; the multi-database additive path is bounded by a 7-day periodic full clear. Per-entry exclusion travels inside KDBX custom data (`KPEX_DoNotSuggestForAutoFill`). New databases default AutoFill *off* (post-first-unlock onboarding opts in). Passkey identities are published even when `quickTypeEnabled` is off.
- Apple's [`ASCredentialIdentityStore`](https://developer.apple.com/documentation/authenticationservices/ascredentialidentitystore) removes identities only by exact object or all at once — there is no filtered removal. But [`credentialIdentities(forService:credentialIdentityTypes:)`](https://developer.apple.com/documentation/authenticationservices/ascredentialidentitystore/credentialidentities(forservice:credentialidentitytypes:)) (iOS 17.4+ / macOS 14.4+, within KeeForge's deployment targets) enumerates everything the app has saved. Enumerate → filter by the database tag in `recordIdentifier` → remove that subset gives KeeForge true per-database removal that works even while every database is locked — strictly better than both comparables' wipe-and-repopulate-lazily strategy, and it eliminates their stale-deleted-entry problem without Strongbox's periodic sweep. The system clears the store itself when the user disables the extension in iOS Settings.

## Stable Core Impact

None. The KDBX parser/writer/crypto files, `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, and `DatabaseDraft.swift` are untouched. The work lives in `DatabaseReference`, `DatabaseListStore`, `CredentialIdentityStoreManager`, the view models, the settings/detail views, and `CredentialProviderCoordinator`. No KDBX format or compatibility-matrix change; `KDBXCompatibilityTests` is unaffected.

## Slice plan

| # | Slice | File | Depends on |
|---|-------|------|------------|
| 01 | AutoFill-enabled flag and publication gating | `01-autofill-enabled-flag.md` | — |
| 02 | Database-tagged credential identities | `02-database-tagged-identities.md` | 01 |
| 03 | Extension identity-to-database resolution | `03-extension-identity-resolution.md` | 02 |
| 04 | Multi-database aggregation and targeted removal | `04-multi-database-aggregation.md` | 02, 03 |
| 05 | Settings UI and Clear AutoFill Entries | `05-settings-ui-and-clear-button.md` | 01, 02, 04 |
| 06 | Extension database switcher *(optional)* | `06-extension-database-switcher.md` | 03 |

The split follows the one hard ordering constraint: identities must be database-tagged (02) and the extension must be able to resolve a tapped identity to its owning database (03) *before* publication becomes additive (04) — otherwise QuickType could surface suggestions the extension cannot fulfill. 01 is pure model/persistence groundwork that already delivers the core guarantee (a disabled database never publishes or hijacks the store) inside today's single-active behavior. UI (05) lands after behavior is final so its copy is truthful. 06 is a small, optional extension-UI convenience enabled by 03's machinery; the feature is complete without it.

## Cross-slice notes

- **Record identifier:** one versioned format defined in slice 02 and used verbatim by every later slice: a prefix-versioned string carrying the owning `DatabaseReference.id` and the entry UUID (KeePassium-style compact encoding, not Strongbox's JSON). Exactly one type owns encode/parse; password, passkey, and one-time-code identities all use it. Parsers must treat the legacy bare-entry-UUID format as "entry in the active database" until slice 04's refresh cycles it out of the store.
- **Active pointer:** `DatabaseListStore.activeAutoFillDatabaseID` survives as "the extension's default database" (manual search, save, passkey registration). From slice 01 on, only databases with AutoFill enabled may be written to it, including the legacy fallback path.
- **Publication timing:** enabling AutoFill for a locked database is lazy — its suggestions appear on next unlock (entries are inside the encrypted KDBX; the cached copy cannot be mined). Disabling is immediate and works while locked (store enumeration needs no decryption). If the database is currently unlocked in the main app, both directions take effect immediately.
- **Threading:** identity-store calls are async and stay off the main thread along with parsing, per repo rules. `DatabaseListStore` mutations keep using its existing lock.
- **Security:** no new secrets or entry metadata are persisted anywhere — the `autoFillEnabled` bool rides in `database-list.json` (App Group; plain bool passes the macOS group-container guardrail, keep `AppGroupGuardrailTests` green), and "which identities exist" lives only inside the OS-managed credential identity store, which is why enumeration is preferred over any App-Group snapshot of domains/usernames. Composite keys stay per-database in the Keychain; the extension's per-database biometric unlock reuses them unchanged.
- **Cross-process races:** main app and extension can both mutate the identity store (unlock vs. in-extension save). Enumerate-then-mutate is not atomic; the accepted worst case is a briefly stale or duplicate suggestion corrected by the next refresh of the affected database. No new IPC is introduced.
- **Shared-target hygiene:** `DatabaseListStore`, `CredentialIdentityStoreManager`, and `AutoFillSaveCoordinator` are in the order-locked shared AutoFill allow-list of both extension targets in `project.yml`; any new source file they gain must be added to **both** lists identically, then `xcodegen generate`.
- **Localization:** every new string lands in `en` and `de` in the affected catalog (app catalogs for slice 05, extension catalogs for slices 03/06); run `LocalizationTests` and `swift scripts/normalize-xcstrings.swift` after catalog edits.
- **CHANGELOG:** slices 01–04 defer; slice 05 adds the epic's user-facing entry:
  `- Choose which databases appear in AutoFill, get suggestions from all of them at once, and clear AutoFill suggestions in Settings.`

## Overall acceptance

- Toggling AutoFill off for a database removes exactly its suggestions (passwords, passkeys, one-time codes) — even while it is locked — and other databases' suggestions are untouched; the extension no longer offers, unlocks, or saves into it.
- With two enabled databases unlocked in sequence, QuickType offers entries from both; tapping either suggestion unlocks the database that owns it, including biometric unlock with that database's composite key.
- Deleting an entry never leaves a stale suggestion beyond its database's next refresh; no periodic sweep exists or is needed.
- Removing a database from the app removes its suggestions even when it was not the active one (fixes a current gap).
- "Clear AutoFill Entries" empties QuickType after confirmation; suggestions rebuild on next unlock/save of enabled databases only.
- After updating from a pre-feature build, existing suggestions keep filling (legacy identifiers resolve against the active database) until the first refresh replaces them; all databases behave as AutoFill-enabled.
- A stale suggestion (database removed/disabled since publication) degrades gracefully: the extension cleans it up and falls back to interactive search or an explanatory empty state — never a dead tap.
- `LocalizationTests`, `AppGroupGuardrailTests`, and all existing AutoFill/registry tests stay green; existing accessibility identifiers are preserved.

## Out of scope

- Per-entry or per-group exclusions (KDBX AutoType flag, `BrowserHideEntry`, Strongbox's `KPEX_DoNotSuggestForAutoFill`) — natural follow-up, different granularity.
- KeePassium-style tri-state inherit-from-global per-database values, premium gating, or MDM overrides.
- QuickType display-format options (Strongbox's `quickTypeDisplayFormat`).
- Identity-count caps or truncation (neither comparable has one; revisit only if a real store limit surfaces).
- Convenience auto-unlock timers in the extension (Strongbox §8) or any change to the global Quick AutoFill toggle's semantics.
- Publishing identities from locked databases, background repopulation, or any App-Group snapshot of entry metadata.
- Website/docs localization beyond the in-app catalogs.
