# Slice 02: Database-Tagged Credential Identities

> Parent: [`epic.md`](./epic.md) · Depends on: 01

## Goal

Make every published credential identity attributable to its owning database via a versioned record identifier, and rebuild `CredentialIdentityStoreManager` around a testable store abstraction that can enumerate, targeted-remove, and clear — while keeping today's publish-one-database-at-a-time behavior.

## Scope

**In:**

- A single owned type that encodes/parses the record identifier: a version-prefixed compact string carrying the owning `DatabaseReference.id` and the entry UUID (KeePassium-style joined fields, not JSON). Parsing must classify three cases: current format, legacy bare-entry-UUID (pre-feature identities — resolves as "entry in the active database"), and unrecognized (stale). Password, passkey, and one-time-code identities all carry it.
- `CredentialIdentityStoreManager` rework:
  - Populate takes the owning database id and tags all identity kinds.
  - New targeted removal: enumerate the store (`credentialIdentities(forService:)`, iOS 17.4+ / macOS 14.4+ — within deployment targets), filter to identities whose identifier parses to the given database id, remove exactly that subset. Must work without any database being unlocked.
  - `clearStore()` retained as the wipe-everything primitive (global toggle off, database-removal fallback, and slice 05's button).
  - All operations still gate on the store's `isEnabled` state and run async off the main thread.
  - Introduce a seam so unit tests can run the enumerate/filter/remove/save logic against an in-memory fake store; the production implementation wraps `ASCredentialIdentityStore.shared`. Keep the existing `#if DEBUG` populate/clear observers working and extend them to expose the owning database id.
- Publication behavior unchanged this slice: unlock/save still replaces the whole store with the one database's (now tagged) identities. The full replace also naturally purges legacy-format identities.
- Extension tolerance: `CredentialProviderCoordinator`'s entry lookup (currently comparing the identifier to `entry.id.uuidString`) parses the identifier and matches on the entry UUID for both current and legacy formats, still searching only the active database. Owning-database resolution is slice 03.

**Out:**

- Additive multi-database publication and targeted-removal *wiring* into toggle/removal events (slice 04).
- Extension unlock of non-active databases (slice 03).
- Any UI (slice 05).

## Affected areas

- Modified: `KeeForge/Services/AutoFill/CredentialIdentityStoreManager.swift`, `AutoFillExtension/CredentialProviderCoordinator.swift`, `KeeForge/ViewModels/DatabaseViewModel.swift` and `KeeForge/Services/AutoFill/AutoFillSaveCoordinator.swift` (pass the owning database id through populate).
- New (if the identifier type or store seam warrants its own file): a small file under `KeeForge/Services/AutoFill/`.

## KeeForge bits

- **Targets:** `CredentialIdentityStoreManager` is in the shared AutoFill allow-list of both extension targets; the coordinator compiles into both extensions **and** the `KeeForge` app target (test hosting). Any new file must be added to the main target **and** to the order-locked shared allow-lists of `KeeForgeAutoFill` and `KeeForgeMacAutoFill` identically.
- **project.yml:** No changes unless a new file is created; if so, add it to all three lists above, update `KeeForge/Services/AutoFill/README.md`, and run `xcodegen generate`.
- **Accessibility identifiers:** N/A — no view-layer work.
- **CHANGELOG:** deferred to the epic's entry.

## Testing

- **Unit:** `CredentialIdentityStoreManagerTests.swift` — identifier encode/parse round-trip; legacy bare-UUID classification; unrecognized-string classification (garbage, wrong version, truncated fields); all three identity kinds (password, passkey, one-time-code) carry the tagged identifier — this replaces the current `recordIdentifier == entry.id.uuidString` assertions; expiry filtering and dedup behavior preserved. Against the fake store: populate writes tagged identities; targeted removal removes only the target database's identities and leaves another database's untouched; targeted removal with nothing matching is a no-op; `clearStore` empties; a disabled store state makes every operation a no-op.
  `CredentialProviderCoordinatorTests.swift` — fill succeeds for a current-format identifier and for a legacy identifier against the active database; an unrecognized identifier falls into the existing not-found/interactive path.
  Run slice: `-only-testing:KeeForgeTests/CredentialIdentityStoreManagerTests -only-testing:KeeForgeTests/CredentialProviderCoordinatorTests`
- **Integration / UI:** N/A — behavior-preserving refactor plus format change; system-store integration is exercised manually.
- **Manual:** on a device/simulator with the extension enabled: unlock a database, verify QuickType suggestions appear and fill; verify a suggestion published by a pre-feature build (legacy identifier) still fills after updating; save an entry from the extension and confirm suggestions refresh.
- **Edge cases that apply:** locked databases during removal (enumeration needs no unlock), store disabled by the user in iOS Settings (system already cleared it; operations no-op), mixed-format store contents mid-migration.

## Exit criteria

- [ ] Unit tests above pass; `DatabaseViewModelTests` observer assertions updated for the database-id-aware seam and green.
- [ ] Manual checks done, including the legacy-identifier fill.
- [ ] Identifier format documented in one place (doc comment on the owning type) and used by every call site.
- [ ] No force unwraps; no secrets logged; store calls off main.
- [ ] `project.yml` + both allow-lists + `xcodegen generate` if a file was added.
- [ ] CHANGELOG explicitly deferred to the epic's entry.

## CHANGELOG entry

N/A — covered by the epic's entry, lands with slice 05.
