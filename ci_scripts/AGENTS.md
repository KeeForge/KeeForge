# CI Scripts

**Scope:** scripts invoked by Xcode Cloud, GitHub Actions, XcodeGen, or the release procedure: build-config bootstrap, generation-time validators, the KDBX compatibility gate, and the release tooling. Hand-run developer tooling lives in `../scripts/`.

## Rules for changing scripts here

- Keep scripts deterministic, noninteractive, and fail-closed: a check that cannot run is a failure.
- Most scripts carry an offline self-test (`--self-test`, `self-test`, `--preflight`, `--fixture`, or a `test_*.sh` beside them). Run it after a change and extend it.
- CI regenerates the project; never assume the checked-in `.xcodeproj` is current. Add new CI-time generation or dependencies to `ci_post_clone.sh`.
- `/.github/` and `/ci_scripts/` are code-owned, so a PR cannot change its own gate without owner review (`../.github/AGENTS.md`).
- When delegating a long local run to a noninteractive CLI (for example `claude -p`), keep that CLI alive until the child exits and its log and canonical result are read. Print-mode exit can kill its children, and a clean CLI exit is not a passed Xcode run. Never start a duplicate run; use fresh result paths for a recovery.
- Local Xcode runs of these scripts take the repo Xcode lock (`../scripts/with-repo-lock.sh`).

## Build configuration

- `prepare_build_config.sh` validates `BuildConfig.local.xcconfig` and stamps `BuildMetadata.xcconfig` with the git hash. With `BOOTSTRAP_LOCAL_CONFIG_FROM_ENV=1` it writes the local config from environment variables, using CI placeholders when CI supplies none.
- An archive (`CI_XCODEBUILD_ACTION=archive`, or `REQUIRE_REAL_CLOUD_KEYS=1`) fails when `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID` is missing or a placeholder, so no shippable binary carries broken cloud sign-in. Elsewhere in CI the placeholders pass and the app treats them as cloud sign-in disabled.
- `ci_pre_xcodebuild.sh` repeats that validation before each `xcodebuild` action because `CI_XCODEBUILD_ACTION` is only reliably set there. Xcode Cloud workflows with an archive action must therefore carry both real values (`../.agents/skills/prepare-release/references/xcode-cloud-setup.md`).
- The Dropbox key is interpolated into the `db-$(DROPBOX_APP_KEY)` URL scheme, so its placeholder `ciplaceholderdropboxappkey` must stay alphanumeric: App Store Connect rejects underscores (ITMS-90158). `KeeForgeTests/URLSchemeFormatTests.swift` checks the built bundle.
- `Configs/BuildConfig.xcconfig` is a checked-in include. It lives in `Configs/` so XcodeGen gives it a stable group name rather than the checkout directory's.
- Local setup: copy `BuildConfig.local.example.xcconfig` to `BuildConfig.local.xcconfig` at the repo root and set `DROPBOX_APP_KEY`. `ONEDRIVE_CLIENT_ID` is optional outside archives.

## Generation-time validators

`project.yml` runs both as XcodeGen's `postGenCommand`, so they run on every `xcodegen generate`, locally and in CI.

- `validate_architecture.py` rejects a SwiftUI import under `KeeForge/ViewModels/` and a direct `SettingsService` preference write in `SettingsView.swift`. It is a narrow regression guard, not a review of workflow ownership.
- `validate_cloud_test_schemes.py` enforces the partition below.

## Xcode Cloud test partition

Xcode Cloud's RC workflow runs three Required-to-Pass schemes: `KeeForgeCloudUnitTests`, `KeeForgeCloudUIA`, and `KeeForgeCloudUIB`. The ordinary `KeeForge` scheme still contains both full suites.

- UI A selects whole classes in `project.yml` (the `cloudUIGroupA` anchor). UI B skips exactly that list through the same anchor, so B is the complement and a new UI class runs in B with no edit.
- The validator rejects a gap, an overlap, a stale class name, a filtered or skipped unit target, a test plan, and any parallel target. Both UI groups stay serial.
- Unit tests have their own scheme so a UI task retry does not repeat them.
- Rebalance by moving class names in the A list when measured Cloud durations for the two UI groups drift apart. Never list a class in B.
- `KeeForgeUITestCase` sets a 300-second execution allowance. Cloud enables test timeouts; pass `-test-timeouts-enabled YES` locally to enforce it.

The live Cloud workflow configuration is in `../.agents/skills/prepare-release/references/xcode-cloud-setup.md`.

## KDBX Compatibility Gate

`run_kdbx_compatibility_gate.sh` proves that databases KeeForge writes open correctly in another KeePass implementation. It runs `KDBXCompatibilityTests`, exports every `.kdbx` the suite wrote, and verifies each one with KeePassXC's `keepassxc-cli`.

**When it is required:** before every release candidate, once per platform, and both runs must pass before any external distribution. No CI runs it, because neither GitHub runners nor Xcode Cloud install KeePassXC, so it is a local gate. Also run it when a change touches the compatibility matrix (see `../KeeForge/AGENTS.md`).

**How to run it:** install KeePassXC, or set `KEEPASSXC_CLI=/path/to/keepassxc-cli`. Run under the Xcode lock.

```bash
ci_scripts/run_kdbx_compatibility_gate.sh                                  # iOS
KDBX_COMPAT_SCHEME=KeeForgeMac ci_scripts/run_kdbx_compatibility_gate.sh   # macOS
```

- The iOS run uses `KeeForgeTests` on the `iPhone 17 Pro` simulator (override with `KDBX_COMPAT_DESTINATION`). The Mac run uses `KeeForgeMacTests`, which compiles the same sources, on `platform=macOS`.
- Each run deletes its result bundle and attachments directory first. Set distinct `KDBX_COMPAT_RESULT_BUNDLE` and `KDBX_COMPAT_ATTACHMENTS_DIR` paths per platform to keep both sets of evidence. The release form of the command, with logs, is in `../.agents/skills/prepare-release/references/candidate.md`.

**What it checks, per artifact:**

- `search` and `ls` for the expected search terms and group paths.
- `attachment-export` plus a SHA-256 comparison for expected attachments.
- `show -s -a Password` for expected passwords. This is the protected-value check: search and listing read only plaintext XML, so a self-consistent but non-conforming protected stream would otherwise pass.
- `export -f xml` for custom fields (values, protection flags, removals, exact history count) and for expiry (`Expires` and `ExpiryTime`). Fields containing carriage returns are also compared against raw `show -a` output, because XML parsing normalizes them.
- `show -t` for TOTP: KeePassXC must generate the code an independent RFC 6238 implementation in the script computes. Codes for the windows just before and after the call are both accepted, so a period rollover cannot flake it.

**Invariants:**

- The suite attaches each scenario's bytes on the way past its own assertions. Do not add a separate artifact-only test; it would repeat the Argon2 work.
- Exported attachment names are mangled, so the script maps them back through xcresulttool's `manifest.json` (`suggestedHumanReadableName` to `exportedFileName`). That mapping is load-bearing.
- Manifest fragments are found by content (a JSON object with an `artifacts` key), merged, and deduplicated by artifact id. Zero fragments, conflicting copies of an id, or an id in `expectedArtifactIDs` that no method emitted all fail the gate.
- Zero TOTP, custom-field, or expiry checks fails the gate even when everything else passed, so a lost expectation table cannot pass silently.

The artifact set is declared in `KeeForgeTests/Support/KDBXCompatibilitySupport.swift` (`artifactDescriptors`) and emitted by `KeeForgeTests/KDBXCompatibilityTests.swift`. `../KeeForgeTests/AGENTS.md` says how to add one.

## Other scripts

Only the scripts whose names do not explain them. Usage is in each script's header.

- `ci_post_clone.sh`, `ci_pre_xcodebuild.sh`: Xcode Cloud hooks. Post-clone installs XcodeGen, prepares the build config, and generates the project.
- `validate_xcresult_summary.py`: the CI verdict. It requires `result=Passed`, zero failures, and at least one executed test in a fresh `.xcresult` summary. `xcodebuild` exit 65 is tolerated only after that check. Fixtures: `test_validate_xcresult_summary.sh`.
- `restore_pre_ui_state.sh`: backs up (`--backup`) and restores the Mac App Group and defaults around the local Mac UI smoke. With neither flag it only inspects; restoring needs `--execute --confirm RESTORE_PRE_UI_STATE`. Fixtures: `test_restore_pre_ui_state.sh`.
- `build_mac_direct.sh`, `verify_mac_artifact.sh`, `verify_sparkle_ed25519.swift`, `release_direct_artifact.sh`, `generate_appcast.py`: the Developer ID direct-download channel only; the Mac App Store build never goes through `build_mac_direct.sh`.
- `make_appstore_screenshots.py` (Mac layout in `mac_screenshot_design.py`): composes App Store listing images from UI-test captures. It does not capture them; its header gives the opt-in capture commands.

## Release procedures

Release steps live with the release skills, under `../.agents/skills/prepare-release/references/`:

- `shared.md`: candidate identity, the manifest, required gates, and the invariants.
- `candidate.md`: build number (`next_repo_build.sh`), both KDBX gate runs, RC tag and manifest (`candidate_manifest.py`), hosted gates, Mac smoke, and beta distribution.
- `direct-distribution.md`: the direct-build safety contract, artifact verification, appcast stage/handoff/publish, the manual Sparkle rehearsal, and ZIP extraction verification.

Elsewhere:

- [`contributor-testing.md`](contributor-testing.md): signed contributor builds through the separate **Contributor Testing** Xcode Cloud workflow.
- `../KeeForgeMac/README.md`: why the Mac ships two channels from two XcodeGen specs.
