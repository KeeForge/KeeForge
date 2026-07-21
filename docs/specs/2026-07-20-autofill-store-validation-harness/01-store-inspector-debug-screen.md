# Slice 01: Store Inspector Debug Screen

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

A DEBUG-only, launch-argument-gated screen that renders the real `ASCredentialIdentityStore`
contents with accessibility identifiers, so XCUITests (slice 03) and humans can assert what
the system store actually holds.

## Scope

**In:**

- When the app launches with a dedicated argument (suggested: `-autofill-store-inspector`),
  present the inspector full-screen at the root instead of the normal database list. The
  argument does nothing in Release builds; the entire feature is `#if DEBUG`.
- The inspector enumerates via the existing `CredentialIdentityStoreProviding` production
  conformance (`SystemCredentialIdentityStore`) and shows:
  - store **enabled** state (`isEnabled()`) as a stable text element ("enabled"/"disabled"),
  - whether **enumeration** is supported (nil result → "enumeration unavailable"),
  - **total identity count**,
  - one section per **database tag**: identities whose `recordIdentifier` parses (via
    `CredentialRecordIdentifier.parse`) to `.current`, grouped by database UUID, showing the
    database's display name when that UUID is registered in `DatabaseListStore.databases`
    (fall back to the raw UUID), the per-database count, and one row per identity with its
    service identifier, username/label, and identity kind (password / passkey / one-time
    code),
  - a **legacy** section (bare-UUID identifiers) and an **unrecognized** section, each with
    counts, shown only when non-empty.
- A **Refresh** control that re-enumerates on demand (tests mutate the store between
  assertions via a second app instance/scenario steps, then refresh).
- Enumeration runs off the main thread (repo rule); the UI shows a simple loading state while
  a refresh is in flight.
- No decrypted secrets: the screen displays only store metadata (identifiers, usernames,
  service identifiers, counts). It never touches `EncryptedValue` or vault contents and does
  not require any database to be unlocked.

**Out:** any mutation of the store from this screen (tests drive mutations through the real
settings/unlock UI); provisioning (slice 02); the lifecycle test suite (slice 03).

## Affected areas

- New: one SwiftUI view file for the inspector (e.g. under `KeeForge/Views/`), plus whatever
  small model helper it needs for grouping parsed identities.
- Modified: app root / scene wiring (`KeeForge/App/`) to branch on the launch argument in
  DEBUG builds — follow the pattern the existing `-ui-testing` argument uses.
- Modified: `KeeForge/Views/README.md` (file map) and `KeeForgeUITests/README.md`
  (new launch argument + identifiers, per repo rules).

## KeeForge bits

- **Targets:** all new/changed files are `KeeForge` app target only. Nothing is added to
  either extension target (keep the view file out of the extension allow-lists).
- **project.yml:** No changes expected (new file lands in an already-globbed directory).
  Run `xcodegen generate`.
- **Accessibility identifiers (new; all existing preserved):**
  - `autofill-inspector.enabled-state` — value "enabled" / "disabled"
  - `autofill-inspector.enumeration-state` — value "available" / "unavailable"
  - `autofill-inspector.total-count`
  - `autofill-inspector.refresh`
  - `autofill-inspector.database.<database-id-uuidString>.count` (uppercase UUID, matching
    the `settings.autofill.database-toggle.<uuid>` convention)
  - `autofill-inspector.legacy.count`, `autofill-inspector.unrecognized.count`
  - Counts as element **values** (strings), so tests can wait for an exact value.

## Testing

- **Unit:** the grouping helper (identities → per-database/legacy/unrecognized buckets with
  counts) is pure given `[any ASCredentialIdentity]` input — cover it in `KeeForgeTests`
  using hand-built `ASPasswordCredentialIdentity` values with current/legacy/garbage
  record identifiers (same construction pattern as
  `CredentialIdentityStoreManagerTests`). Scenarios: mixed tags group correctly; registered
  database resolves display name while unregistered shows UUID; empty store yields empty
  buckets. Run slice: `-only-testing:KeeForgeTests/<new grouping test class>`.
- **Integration / UI:** one smoke test in the **default** `KeeForgeUITests` suite (safe on
  unprovisioned simulators): launch with the inspector argument, assert the screen appears
  and `autofill-inspector.enabled-state` reads "disabled" — pinning that the argument works
  and the disabled state renders. This is the only harness surface allowed in the default
  suite.
- **Manual:** on the provisioned harness simulator (after slice 02): launch with the
  argument after unlocking a database normally; confirm the published identities appear
  under the right database name; toggle the database off in the app; refresh; confirm the
  section empties.
- **Edge cases that apply:** store disabled (renders "disabled", no crash), enumeration
  returning nil, unregistered database UUIDs (removed database's leftovers), zero
  identities, refresh spammed while a refresh is in flight.

## Exit criteria

- [ ] Unit tests above pass.
- [ ] Default-suite smoke test passes on an unprovisioned simulator.
- [ ] Manual checks done on the harness simulator.
- [ ] CHANGELOG entry written, or explicitly deferred to the epic's entry.
- [ ] No force unwraps; no secret access; enumeration off main.
- [ ] `xcodegen generate` run if `project.yml` changed.

## CHANGELOG entry

`N/A — developer tooling; the epic declares no user-facing entry.`
