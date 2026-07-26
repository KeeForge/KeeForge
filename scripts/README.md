# Scripts

Local developer tooling. Folder rule: hand-run scripts live here; anything CI or Xcode Cloud invokes lives in `ci_scripts/` (see `ci_scripts/README.md`).

## Current Scripts

- `normalize-xcstrings.swift` — rewrites `.xcstrings` catalogs into Xcode's canonical serialization (space-padded ` : `, `localizedStandardCompare` key order, expanded empty objects, no trailing newline); without it a plain-JSON edit produces a large reordering diff on Xcode's next round trip. Run `swift scripts/normalize-xcstrings.swift` after any programmatic catalog edit (per `AGENTS.md`): no args = all tracked catalogs, file args restrict the set, `--check` writes nothing and exits non-zero on drift (no CI job runs it). Swift on purpose — the key order depends on Foundation's `localizedStandardCompare`.
- `provision-autofill-harness-sim.sh` — provisions the `KeeForge-AutoFill-Harness` simulator the AutoFill store XCUITests assume: resolves a runtime/device type, creates or reuses and boots the device, builds (or accepts `--app-path`) and installs the Debug app, then polls the status-log channel until KeeForge reports itself enabled as credential provider. Only the one Settings toggle is manual; runs are idempotent. Flags, verification contract, and exit codes 0–10 are in the script header; full workflow in "AutoFill Store Harness Simulator" in `KeeForgeUITests/README.md`.

## Guidance

- Keep scripts runnable from the repo root with no setup beyond standard dev tooling (`swift`, `xcrun`, `jq`).
- If a script must run in CI or Xcode Cloud, move or duplicate it into `ci_scripts/`.
