# CI Scripts

This folder holds small scripts used by Xcode Cloud and local build setup.

## Current Script

- `prepare_build_config.sh` validates `BuildConfig.local.xcconfig`, stamps `BuildMetadata.xcconfig` with the current git hash, and can bootstrap the local config from environment variables in CI.
- `ci_post_clone.sh` installs XcodeGen, prepares the build config, and regenerates the Xcode project after checkout.
- `ci_pre_xcodebuild.sh` re-runs `prepare_build_config.sh` right before each `xcodebuild` action, where `CI_XCODEBUILD_ACTION` is reliably set, so an `archive` workflow without a real `DROPBOX_APP_KEY` fails before it produces a binary.
- `run_kdbx_compatibility_gate.sh` validates KeeForge-written databases with `keepassxc-cli`. This is a required local release gate; Xcode Cloud does not install KeePassXC. See "KDBX Compatibility Gate" below.
- `make_appstore_screenshots.py` formats raw screenshots from `build/screenshots` into App Store-ready images in `build/appstore`. It does not capture the raw screenshots itself — see its header comment for the `xcodebuild`/`xcresulttool` steps that populate `build/screenshots` first, including the `TEST_RUNNER_APPSTORE_SCREENSHOTS=1` argument the opt-in `AppStoreScreenshots` UI test class requires (it `XCTSkip`s by default).

## KDBX Compatibility Gate

1. Run `-only-testing:KeeForgeTests/KDBXCompatibilityTests`. The matrix suite writes each scenario's `.kdbx` bytes as an XCTAttachment on the way past its own assertions — there is no separate artifact-only test re-running the (Argon2-expensive) scenarios.
2. `xcrun xcresulttool export attachments` dumps the attachments. Exported file names are mangled to UUIDs, so the script maps them back through xcresulttool's own `manifest.json` index (`suggestedHumanReadableName` → `exportedFileName`). That mapping is load-bearing; do not simplify it away.
3. Collect the **manifest fragments**. Each emitting test method attaches one, so the script finds them by content — any exported file that parses as a JSON object with an `"artifacts"` key — rather than by name. Fragments are merged and deduped by artifact id; conflicting copies of the same id, zero fragments found, or any id in `expectedArtifactIDs` that no method emitted all fail the gate.
4. Verify each merged artifact with `keepassxc-cli`:
   - `search` for every `expectedSearchTerms` entry, `ls` for every `expectedGroupPaths` entry.
   - `attachment-export` plus a SHA-256 comparison for every `expectedAttachments` entry (the `attachments.kdbx`- and `unknown-inner-header.kdbx`-derived artifacts).
   - `show -s -a Password` for every `expectedPasswords` entry. This is the only check that decrypts anything: searching and listing only read plaintext XML, so without it a protected-value stream that is self-consistent but non-conforming would pass the whole gate. Every fixture-smoke artifact verifies both a password KeeForge just wrote and one the fixture already carried (authored by another KeePass implementation), covering AES, ChaCha20, Twofish, key-file, KDBX 4.1, unknown-XML, unknown-inner-header, and attachment databases; the rich `create-entry`/`update-entry` artifacts cover a created and an edited password.
   Entry paths are resolved by exact-title `search` hit (and cached), so entries that moved into the Recycle Bin or were renamed by the edit still resolve.
5. On success the script prints the artifact count, attachment-check count, and protected-password-check count.

The artifact set includes a Twofish-256-CBC database, providing an external KeePassXC opener check for KeeForge's cipher-preserving output. The KeeOTP artifact retains all raw source variants for the XCTest compatibility matrix, but probes a standard entry externally because KeePassXC 2.7.12 does not expose those KeeOTP fields through its XML reader/search path.

The artifact set itself is declared in `KeeForgeTests/KDBXCompatibilitySupport.swift` (`artifactDescriptors`) and emitted by `KeeForgeTests/KDBXCompatibilityTests.swift`; see `KeeForgeTests/README.md` for how to add one.

## Guidance

- Keep these scripts deterministic and noninteractive.
- If CI needs new generated files or dependencies, add them here instead of assuming the checked-in `.xcodeproj` is current.
- `Configs/BuildConfig.xcconfig` is a checked-in include file, not a generated source of truth. It lives in `Configs/` (not the repo root) so XcodeGen wraps it in a stable `Configs` group instead of one named after the checkout directory.
- Local developers should copy `BuildConfig.local.example.xcconfig` to `BuildConfig.local.xcconfig` (both at the repo root), fill in `DROPBOX_APP_KEY`, and optionally add `ONEDRIVE_CLIENT_ID` to test OneDrive OAuth.
- Xcode Cloud **must** provide `DROPBOX_APP_KEY` and `ONEDRIVE_CLIENT_ID` as environment variables on any workflow with an archive action. That is now the **Release Candidate** workflow on `rc/*` tags, which archives to TestFlight after its test action passes — no workflow triggers on `v*` (see `.agents/skills/release/xcode-cloud-setup.md`). For non-archive actions `ci_post_clone.sh` falls back to CI-only placeholders so project generation still succeeds. An archive (or a run with `REQUIRE_REAL_CLOUD_KEYS=1`) whose `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID` is missing or still a placeholder fails the build instead of shipping non-working cloud sign-in. Outside archives, `ONEDRIVE_CLIENT_ID` stays optional — the app just disables OneDrive sign-in.
- GitHub Actions can keep using simulator-safe placeholder values to materialize `BuildConfig.local.xcconfig`; the app treats the CI placeholders as cloud providers disabled for real sign-in.
- The Dropbox key is interpolated into the `db-$(DROPBOX_APP_KEY)` `CFBundleURLScheme`, so the CI placeholder is `ciplaceholderdropboxappkey` — alphanumerics only. The old `CI_PLACEHOLDER_DROPBOX_APP_KEY` value contains underscores, which App Store Connect rejects with ITMS-90158; keep any new placeholder RFC1738-legal. `KeeForgeTests/URLSchemeFormatTests.swift` enforces this on the built app bundle.
- To run the KDBX compatibility gate locally, install KeePassXC or set `KEEPASSXC_CLI=/path/to/keepassxc-cli`, then run `ci_scripts/run_kdbx_compatibility_gate.sh`. Override `KDBX_COMPAT_DESTINATION` if the default `iPhone 17 Pro` simulator is unavailable.
- To regenerate App Store image composites after exporting raw screenshot PNGs into `build/screenshots`, run `ci_scripts/make_appstore_screenshots.py`. Populate `build/screenshots` first by running the opt-in `KeeForgeUITests/AppStoreScreenshots` UI test class with `TEST_RUNNER_APPSTORE_SCREENSHOTS=1` and exporting its attachments (see the script's header comment for the exact commands).
