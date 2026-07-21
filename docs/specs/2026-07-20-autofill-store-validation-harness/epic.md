# Epic: AutoFill Store Validation Harness

## Summary

An opt-in, local-Mac test harness that asserts the app's AutoFill behavior against the **real**
`ASCredentialIdentityStore` on a dedicated, pre-provisioned simulator — converting most of the
remaining manual AutoFill checks from
[`2026-07-19-selectable-autofill-per-database/deferred-tests.md`](../2026-07-19-selectable-autofill-per-database/deferred-tests.md)
(the per-slice "Manual checks" sections) into deterministic XCUITest assertions.

**Why this is possible now.** A feasibility probe (2026-07-20, iPhone 17e / iOS 26.5 simulator,
Xcode 26.6) proved the full third-party AutoFill pipeline works in the simulator: KeeForge is
listed and toggleable under Settings → General → AutoFill & Passwords, published identities
appear as Safari inline suggestions, the extension unlock UI presents, and credentials fill a
real web form. Once a simulator has the provider enabled (state persists until erase), the real
system store is live for automated assertions — the historical "everything silently no-ops"
failure mode only applies to unprovisioned simulators.

**What stays out.** Driving Safari/QuickType from XCUITest (covered by the agent-driven Tier-3
routine instead), Face ID automation, the Mac extension, and CI/Xcode Cloud execution.

## Clarified requirements

- **Q:** Where must the Tier-2 store-assertion tests be able to run?
  **A:** Local Mac only — a dedicated, pre-provisioned simulator; provisioning is a one-time
  scripted step the tests assume. No Xcode Cloud/CI support in this epic.
- **Q:** What form should the store-introspection channel take?
  **A:** Hidden debug screen — DEBUG-only SwiftUI view shown only under a launch argument,
  listing per-database identity counts and tags with accessibility identifiers.
- **Q:** Should the harness be wired into the release process now?
  **A:** Not yet — ship as an opt-in suite + documented recipe; revisit release-gating after
  it has proven stable across a few runs.

## Stable Core Impact *(KeeForge only)*

`None` — the harness only **reads** the system store through the existing
`SystemCredentialIdentityStore` seam and drives existing UI. No stable-core file changes.

## Slice plan

| # | Slice | File | Depends on |
|---|-------|------|------------|
| 01 | Store inspector debug screen | `01-store-inspector-debug-screen.md` | — |
| 02 | Harness simulator provisioning | `02-harness-simulator-provisioning.md` | — |
| 03 | Store lifecycle UI tests | `03-store-lifecycle-ui-tests.md` | 01, 02 |

Why this split: slice 01 is app code with its own (unprovisioned-simulator) smoke coverage;
slice 02 is pure tooling, testable by running it against a fresh simulator; slice 03 is the
payoff and needs both. Slices 01 and 02 are independent of each other and can land in either
order.

## Cross-slice notes

- **Store reads:** always through `CredentialIdentityStoreProviding` /
  `SystemCredentialIdentityStore` (enumeration requires iOS 17.4+; the harness targets the
  iOS 26.x simulator, so no fallback UI is needed beyond an "enumeration unavailable" state).
- **Security:** no decrypted secrets are read or displayed anywhere in this epic. The
  inspector shows only store metadata: enabled state, counts, service identifiers, usernames,
  and parsed `CredentialRecordIdentifier` tags. All inspector code is `#if DEBUG`.
- **Lock state:** the inspector requires no unlocked vault (enumeration is store-level).
  Lifecycle tests that need publication drive real fixture unlocks through existing UI.
- **Harness device:** one named, long-lived simulator (suggested name
  `KeeForge-AutoFill-Harness`, iPhone-class, newest installed iOS runtime). Tests must not
  assume it is the default `iPhone 17 Pro` device used by the regular suites.
- **Guard rail (all slices):** harness tests must skip cleanly (`XCTSkip`) when the store is
  disabled, so an accidental run in the default suites or on an unprovisioned simulator
  produces skips, never false greens or hangs.
- **Text input on the simulator:** synthetic keystrokes are flaky (probe finding: stuck
  accent-picker popup); anything scripted that types should prefer pasteboard-based entry
  (`simctl pbcopy` + paste) or XCUITest `typeText` (which uses a different, reliable path).
- **CHANGELOG:** developer tooling only — no user-facing entry for the epic. Slices defer.

## Out of scope

- Safari/QuickType end-to-end assertions from XCUITest (Tier-3 agent routine owns those).
- Face ID / biometric automation.
- macOS app or Mac extension coverage.
- Xcode Cloud / CI execution and release-workflow integration.
- Any change to AutoFill production behavior.
