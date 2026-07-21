# Slice 02: Harness Simulator Provisioning

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

A repeatable, mostly-scripted recipe that produces the dedicated harness simulator: booted,
app installed, and KeeForge enabled as the credential provider — the precondition slice 03's
tests assume.

## Scope

**In:**

- A script (suggested: `scripts/provision-autofill-harness-sim.sh`) that:
  1. Creates the named simulator if missing (suggested name `KeeForge-AutoFill-Harness`,
     iPhone-class device, newest installed iOS runtime), or reuses it if present.
  2. Boots it and waits for `simctl bootstatus`.
  3. Builds (or accepts a path to) the Debug `KeeForge.app` and installs it via
     `simctl install`.
  4. Opens the provider settings pane to minimize the manual step (deep-linking into
     Settings; at minimum `simctl launch <udid> com.apple.Preferences` — probe-verified
     path: **General → AutoFill & Passwords → toggle KeeForge on**; optionally also toggle
     Apple's "Passwords" provider off for cleaner signal).
  5. Waits for and **verifies** enablement before exiting 0: poll by launching the app with
     the slice 01 inspector argument plus a verification channel the script can read
     (recommendation: a second DEBUG launch argument that makes the app log a single
     machine-greppable line with the store's `isEnabled()` result, read host-side via
     `simctl spawn <udid> log`; the implementer may choose another script-readable channel).
     Exit non-zero with a clear message if enablement is not confirmed within a timeout.
- The one manual (or agent-driven) action — flipping the toggle in Settings — is printed as
  an explicit numbered instruction while the script polls. Everything else is unattended.
  (Local-Mac-only per the epic; no attempt to script the Settings UI itself.)
- An `--erase` flag that erases the device first for a from-scratch rebuild (documents that
  erasing loses provider enablement).
- Recipe documentation in the script header plus a short section in
  `KeeForgeUITests/README.md` (how to provision, how to re-verify, that state persists
  until erase).

**Out:** the inspector itself (slice 01 — the script only uses its launch argument for
verification, and must degrade gracefully with a clear error if the installed build lacks
it); the test suite (slice 03); any CI variant.

## Affected areas

- New: `scripts/provision-autofill-harness-sim.sh`.
- Modified: `KeeForgeUITests/README.md` (provisioning section), `scripts/` README or header
  comment if the folder keeps an index.

## KeeForge bits

- **Targets:** none — tooling only.
- **project.yml:** No changes. (`xcodegen generate` not required.)
- **Accessibility identifiers:** N/A — no view changes.

## Testing

- **Unit:** N/A — shell tooling; correctness is validated by execution.
- **Integration / UI:** run the script end-to-end twice on this Mac:
  1. From nothing (device absent) → script creates/boots/installs, prints the toggle
     instruction, and exits 0 once the toggle is flipped.
  2. Re-run on the provisioned device → verification passes immediately with no manual step
     (idempotence).
  Also verify the failure path: run against a freshly `--erase`d device and let the timeout
  expire without flipping the toggle → non-zero exit with the clear message.
- **Manual:** after provisioning, spot-check in Settings that KeeForge shows enabled; launch
  the app with the inspector argument and confirm `autofill-inspector.enabled-state` reads
  "enabled".
- **Edge cases that apply:** Simulator app not running (script must work headless via
  `simctl` for everything except the manual toggle), multiple devices with the harness name
  (fail with guidance rather than guessing), stale/incompatible installed app build
  (reinstall path).

## Exit criteria

- [ ] Both end-to-end runs above behave as specified (fresh + idempotent re-run).
- [ ] Failure path exits non-zero with actionable output.
- [ ] Manual checks done.
- [ ] CHANGELOG entry written, or explicitly deferred to the epic's entry.
- [ ] Recipe documented in `KeeForgeUITests/README.md`.

## CHANGELOG entry

`N/A — developer tooling; the epic declares no user-facing entry.`
