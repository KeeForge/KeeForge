# Scripts

Local developer tooling. Folder rule: scripts a developer (or agent) runs by hand on their machine live here; scripts invoked by CI or Xcode Cloud live in `ci_scripts/` (see `ci_scripts/README.md`).

## Current Scripts

- `normalize-xcstrings.swift` rewrites `.xcstrings` catalogs into Xcode's canonical String Catalog serialization (space-padded ` : ` separators, `localizedStandardCompare` key order, expanded empty objects, no trailing newline). Xcode reserializes catalogs on open/build, so a plain-JSON edit otherwise produces a massive whitespace/reordering diff on the next round trip. Run `swift scripts/normalize-xcstrings.swift` after **any** programmatic catalog edit (per `AGENTS.md`): no args processes every tracked `*.xcstrings`; explicit file args restrict the set; `--check` writes nothing and exits non-zero on drift (available for verification; no CI job runs it). It is Swift on purpose — the key order depends on Foundation's `localizedStandardCompare`, which cannot be faithfully reproduced in another language.
- `provision-autofill-harness-sim.sh` provisions the dedicated `KeeForge-AutoFill-Harness` simulator that the AutoFill store XCUITests assume: resolves a runtime/device type, creates or reuses the device, boots it, builds (or accepts via `--app-path`) and installs the Debug app, then polls the app's status-log channel until KeeForge reports itself enabled as the credential provider. Only flipping the one Settings toggle is manual; runs are idempotent. Flags, the verification contract, and exit codes 0–10 are documented in the script header; the full workflow doc is the "AutoFill Store Harness Simulator" section of `KeeForgeUITests/README.md`.

## Guidance

- Keep scripts here runnable directly from the repo root with no setup beyond standard dev tooling (`swift`, `xcrun`, `jq`).
- If a script needs to run in CI or Xcode Cloud, move or duplicate it into `ci_scripts/` rather than pointing CI at this folder.
