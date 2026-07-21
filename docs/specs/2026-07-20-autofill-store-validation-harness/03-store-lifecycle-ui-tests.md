# Slice 03: Store Lifecycle UI Tests

> Parent: [`epic.md`](./epic.md) · Depends on: 01, 02

## Goal

An opt-in XCUITest class that drives real app flows on the provisioned harness simulator and
asserts, through the slice 01 inspector, that the real `ASCredentialIdentityStore` ends up in
the documented state for each AutoFill lifecycle transition.

## Scope

**In:**

- New class (suggested: `AutoFillStoreUITests`) in `KeeForgeUITests/`, structured on the
  existing base-class conventions (`-ui-testing` fixture injection, per-test relaunch), with
  one hard rule: **every test begins by checking store state via the inspector and calls
  `XCTSkip` when the store is disabled or enumeration is unavailable.** A run in the default
  suites or on an unprovisioned simulator must produce skips, never failures, hangs, or
  false greens.
- Covered lifecycle scenarios (each asserts through inspector counts/sections after driving
  the real UI; identity **presence and ownership**, not Safari behavior):
  1. **Publication on unlock** — unlock fixture database A; its tagged section appears with
     a non-zero count matching A's eligible fixture entries.
  2. **Targeted removal on disable** — with A published, disable A via the per-database
     AutoFill toggle; A's section empties; nothing else changes.
  3. **Lazy republish on re-enable** — re-enable A; count stays zero until A's next unlock,
     then reappears.
  4. **Clear AutoFill Entries** — with identities present, run the confirmed clear action;
     total count reaches zero.
  5. **Multi-database union** — unlock A, then B: both sections present simultaneously;
     then remove/disable one and confirm only its section vanishes (the aggregation
     contract).
- A short doc block at the top of the file stating the precondition (slice 02 recipe), the
  dedicated device name, and the exact run command (`-only-testing` against the harness
  simulator by name/UDID).
- `KeeForgeUITests/README.md` gains a harness section: what the class covers, that it is
  excluded from normal runs by its skip guard, and which deferred-tests manual checks it
  replaces (cross-reference the
  [`selectable-autofill-per-database` manual sections](../2026-07-19-selectable-autofill-per-database/deferred-tests.md)).

**Out:** Safari/QuickType interaction, extension-UI flows (suggestion tap, switcher), save
sheets — Tier-3 agent territory. No new app code (if a needed hook is missing, that is a
slice 01 amendment, not ad-hoc app changes here).

## Affected areas

- New: `KeeForgeUITests/AutoFillStoreUITests.swift` (name at implementer's discretion).
- Modified: `KeeForgeUITests/README.md`.

## KeeForge bits

- **Targets:** `KeeForgeUITests` only.
- **project.yml:** No changes expected (test file lands in the globbed directory). Run
  `xcodegen generate`.
- **Accessibility identifiers:** none added; consumes slice 01's `autofill-inspector.*` and
  the existing `database-details.autofill-toggle` / `settings.autofill.*` identifiers —
  all preserved.

## Testing

This slice **is** tests; its own verification bar:

- **Integration / UI:** on the provisioned harness simulator, the full class passes twice
  consecutively (determinism), and each scenario's assertions are inspector-value waits
  (`waitForExistence` + value polling), never fixed sleeps. On an **unprovisioned**
  simulator, the full class reports all-skipped and finishes fast.
- **Interplay risk to resolve during implementation:** the `-ui-testing` bootstrap reseeds
  the registry on every launch — determine (and document in the file) how per-test
  relaunches interact with persisted `autoFillEnabled` flags and the *system store's*
  cross-launch persistence; scenarios must produce their own preconditions rather than
  relying on run order. Note the store may contain residue from earlier runs or manual use —
  each test must establish a known store state first (e.g. via the clear action) instead of
  assuming emptiness.
- **Manual:** N/A — this slice replaces manual checks; the residual manual list stays in the
  deferred-tests document.
- **Edge cases that apply:** database disabled while locked (registry-only flip), leftover
  identities from a removed database, simulator relaunch between scenario steps
  (background→foreground refresh path), skip guard on the default suite.

## Exit criteria

- [ ] Full class green twice consecutively on the harness simulator.
- [ ] Full class all-skips cleanly on an unprovisioned simulator.
- [ ] README harness section written, incl. which manual checks are now automated.
- [ ] CHANGELOG entry written, or explicitly deferred to the epic's entry.
- [ ] `xcodegen generate` run if `project.yml` changed.

## CHANGELOG entry

`N/A — developer tooling; the epic declares no user-facing entry.`
