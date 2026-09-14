# CI Scripts

This folder holds small scripts used by Xcode Cloud and local build setup.

## Scripts

- `prepare_build_config.sh` validates `BuildConfig.local.xcconfig`, stamps `BuildMetadata.xcconfig` with the current git hash, and can bootstrap the local config from environment variables in CI.
- `ci_post_clone.sh` installs XcodeGen, prepares the build config, and regenerates the Xcode project after checkout.
- `ci_pre_xcodebuild.sh` re-runs `prepare_build_config.sh` right before each `xcodebuild` action, where `CI_XCODEBUILD_ACTION` is reliably set, so an `archive` workflow without a real `DROPBOX_APP_KEY` fails before it produces a binary.
- `run_kdbx_compatibility_gate.sh` validates KeeForge-written databases with `keepassxc-cli`. This is a required local release gate; Xcode Cloud does not install KeePassXC. Install KeePassXC or set `KEEPASSXC_CLI=/path/to/keepassxc-cli`, and override `KDBX_COMPAT_DESTINATION` if the default `iPhone 17 Pro` simulator is unavailable. Set `KDBX_COMPAT_SCHEME=KeeForgeMac` to run the same gate against the macOS app (which switches the test target to `KeeForgeMacTests` and the destination to `platform=macOS`); both platforms must pass before a release. Each run deletes its result bundle and attachments directory first, so give the two runs distinct `KDBX_COMPAT_RESULT_BUNDLE` and `KDBX_COMPAT_ATTACHMENTS_DIR` paths to keep both platforms' evidence. See "KDBX Compatibility Gate" below.
- `next_repo_build.sh` scans reachable `project.yml` history and candidate manifests for the global build floor. Run `ci_scripts/next_repo_build.sh --no-fetch` after the release bookkeeping refs are already current; its self-test covers historical missing Mac targets, unequal legacy builds, current invariant failures, malformed manifests, and the monotonic floor.
- `candidate_manifest.py` creates `scratch/release-manifests/{version}-b{repoBuild}.json` from an existing immutable RC tag without overwriting an earlier record. `init --rc-tag rc/{version}-b{repoBuild}` captures its exact commit/tree identity. `validate --mode distribute|ship` reports missing evidence; pending is never a pass. An adjudication is restricted to an evidenced XCTest reproduction, while ship additionally requires explicit production review/go and accepted soak evidence.
- `build_mac_direct.sh` archives, exports, notarizes and staples the **Developer ID direct-download** macOS build, then emits the zip the Sparkle appcast serves. It regenerates the project from `project-direct.yml` first (the overlay spec that adds Sparkle and defines `KEEFORGE_DIRECT_DOWNLOAD`) and restores the App Store spec on exit. It requires a clean checkout exactly at `rc/{version}-b{repoBuild}`, defaults to `build/mac-direct-{version}-b{repoBuild}`, and refuses an output that already contains `direct-artifact.json`. It refuses to submit anything to Apple unless the exported app is sandboxed, has no `get-task-allow`, and carries no `com.apple.security.cs.*` exception. Needs a Developer ID certificate and a `notarytool` keychain profile. The Mac App Store build does **not** go through this script. It records the RC tag, notarization ID, and artifact facts in `direct-artifact.json`; it does not publish the asset. `--preflight` is offline and checks output, completed-output, RC identity through the normal entry path with a stubbed `xcrun`, portable Sparkle signature parsing, clean-worktree, and `Package.resolved` restoration guards.
- An interrupted direct build is not retried into the same candidate output: `notarization.json`, a `KeeForge-*-b*.zip`, or `direct-artifact.json` stops the script before it can rearchive accepted bytes. `sparkle-signature.txt` is saved before parsing so a parser failure preserves the exact signed ZIP attributes. Retain that output, inspect the ZIP/signature/notarization evidence, and manually finish its metadata or handoff; do not automatically rebuild it.
- `build_mac_direct.sh` packages the release zip with `ditto --sequesterRsrc` and then extracts it with plain `unzip` and re-runs Gatekeeper and `stapler validate` on the result, failing closed. Without the flag, `ditto`'s inline AppleDouble entries become real `._name` files inside the bundle under any non-Apple extractor — unsealed content that makes Gatekeeper reject the app the user downloaded while the exported `.app` on the build machine still passes.
- `verify_mac_artifact.sh` is a fail-closed, artifact-level check for an already exported `.app`; it does not build, sign, notarize, contact Apple, or read a private key. Run it against the exact exported app, never an archive payload substitute: `ci_scripts/verify_mac_artifact.sh --channel mas --app <exported-app> --architectures arm64,x86_64 --expect-version {version} --expect-build {macTestFlightBuild}`. The direct command is `ci_scripts/verify_mac_artifact.sh --channel direct --app <exported-app> --architectures arm64,x86_64 --expect-version {version} --expect-build {repoBuild}`. It prints the actual version/build plus channel evidence and checks the code signature, hardened runtime, sandbox, nested executable bundles, channel framework/linkage boundaries, feed/key presence, and exact architectures.
- It also checks the sandbox exceptions the update channel depends on, because nothing earlier in an update fails without them — the feed fetch, download and EdDSA check all succeed and only the install step is unreachable. A direct artifact must set `SUEnableInstallerLauncherService`, carry mach-lookup exceptions for its own `-spks` and `-spki` names, and keep Sparkle's XPC services inside `Sparkle.framework` rather than in `Contents/XPCServices`. A MAS artifact must carry no `temporary-exception` entitlement at all and must not enable the service.
- Architecture equality covers the root app and KeeForge-owned AutoFill `.appex` executables. Direct StoreKit linkage is checked across every Mach-O binary outside Sparkle's own framework/helpers, so a nested app cannot hide an accidental StoreKit dependency and Sparkle's legitimate updater helpers do not create a false positive.
- `release_direct_artifact.sh` stages a complete appcast and performs the guarded direct-channel handoff. `stage` validates the build JSON and preserves older appcast items while recording the base-feed SHA (or explicit absence) and staged-feed SHA. `handoff` requires local **and origin** `v{version}` and `rc/{version}-b{repoBuild}` tags to resolve to the artifact SHA. It creates a new draft release, or safely resumes only an exact existing draft: an absent asset is uploaded once, while a present asset is downloaded through the GitHub API and verified without clobbering. Published or mismatched releases fail closed. It never publishes the appcast. `verify-public-url` separately verifies the final public download URL and writes evidence; `publish-appcast --staged FILE --metadata FILE --public-verification FILE --destination FILE` is the explicit final step. It requires the evidence, compares the destination with the staged base SHA, and atomically replaces it only on a match (or explicit absence). `--fixture DIR` exercises zip/hash validation, draft-verification abstraction, base mismatch refusal, duplicate refusal, older-item preservation, and atomic publication with no network, `gh`, Apple, notarization, or build.
- `generate_appcast.py` is the deterministic, standard-library appcast builder used by the staging and fixture paths. It inserts the new signed item ahead of older items and rejects a duplicate version/build.
- `make_appstore_screenshots.py` formats raw screenshots into App Store-ready images, for either listing: `--platform iphone` (the default) reads `build/screenshots` and writes `build/appstore` at 1320×2868; `--platform mac` reads `build/screenshots-mac` and writes seven 2880×1800 RGB PNGs to `build/appstore-mac`, named in listing order (`01-native-mac.png` through `07-privacy.png`, mapped from `MacScreenshotAuditUITests` captures in the script's `PLATFORMS["mac"]["screens"]`), plus `layout-report.json` (source file and SHA-256, font, text and window bounds). The Mac design lives in `mac_screenshot_design.py`: a white-to-pale-blue background, a centred SF Pro headline and subhead (Helvetica Neue if SF Pro is absent), and the whole capture uniformly scaled (never above 1:1) with its own alpha corners and a quiet shadow — no added chrome. Every screen is laid out before anything is written: a headline that does not fit shrinks, then wraps to two lines, and a layout that still leaves the margins fails the run. `--output-dir` redirects output for previews, e.g. `ci_scripts/make_appstore_screenshots.py --platform mac --input-dir <export> --output-dir scratch/appstore-mac-preview`. It does not capture the raw screenshots itself — see its header comment for the `xcodebuild`/`xcresulttool` steps per platform, including the opt-in gates each capture class requires (`TEST_RUNNER_APPSTORE_SCREENSHOTS=1` for `AppStoreScreenshots`, `TEST_RUNNER_SCREENSHOT_AUDIT=1` for `MacScreenshotAuditUITests`; both `XCTSkip` by default, and both variables must be real environment variables on the `xcodebuild` process). Point `--input-dir` at an `xcresulttool export attachments` directory as-is: when it contains `manifest.json`, screens are matched through `suggestedHumanReadableName` to the UUID-named exported files (plain `01-database-list.png`-style names also work). For the iPhone listing a missing screen is a warning; for the Mac listing a missing or ambiguous screen, or any `00-skipped-captures` attachment, fails the run before anything is written. `--self-test` checks that resolution, Mac output names and dimensions, text wrapping, uniform window scaling, and corner alpha against disposable fixtures.

## Three-channel release evidence

One `rc/{version}-b{repoBuild}` tag is the identity for one candidate. All four product targets
(`KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, and `KeeForgeMacAutoFill`) carry the same marketing
version and globally monotonic `CURRENT_PROJECT_VERSION`; never reset the repo build for a new
minor, major, patch, or respin. The direct Mac build's `CFBundleVersion` equals that repo build.
Xcode Cloud may assign separate iOS and Mac App Store TestFlight build numbers, so do not force
them to match the repo build or each other: match both processed builds back to the RC tag/SHA.

The candidate manifest is working evidence at
`scratch/release-manifests/{version}-b{repoBuild}.json`. It records `schemaVersion`, version/repo
build/tag/SHA/source tree, iOS and Mac TestFlight build numbers and version-record identifiers,
distribution timestamps and soak metrics, the Xcode Cloud/iOS GitHub/macOS GitHub verdict URLs,
both KDBX gate logs, local Mac smoke result, direct zip filename/URL/SHA-256, Sparkle signature,
notarization submission ID, archive/symbol paths, review states, release timestamps, and accepted
exceptions. It must contain no passwords, tokens, credentials, private keys, keychain profiles, or
cloud secret values. Preserve the completed non-secret manifest with final release evidence; the
scratch copy is not a source of secrets or a release trigger.

The RC gates are all required before external distribution: Xcode Cloud's iOS/Mac test-and-archive
workflow, `.github/workflows/ios18-rc-tests.yml`, `.github/workflows/macos-rc-tests.yml`, both
invocations of `run_kdbx_compatibility_gate.sh` (iOS and `KDBX_COMPAT_SCHEME=KeeForgeMac`), and the
unlocked local `KeeForgeMacUITests/MacSmokeUITests`. After the MAS archive, build and stage the
direct artifact from the same clean SHA; do not publish its GitHub Release asset or production
appcast until both App Store submissions have code approval and the final go decision. The first
coordinated launch uses manual release for both App Store records; preserve existing rating and
make any macOS phased-release choice only when explicitly decided.

## Direct artifact handoff

After the MAS archive and direct build are accepted, the direct build directory contains
`direct-artifact.json`, whose non-secret fields include the version/build, source commit and tree
SHA, exact zip name/path, SHA-256, byte size, notarization submission ID, Sparkle enclosure
attributes, and archive/symbol paths. Stage the unpublished feed with:

```bash
ci_scripts/release_direct_artifact.sh stage \
  --artifact-json build/mac-direct/direct-artifact.json \
  --output-dir scratch/direct-release \
  --input-appcast /path/to/current-appcast.xml
```

For the first public direct release use `--new-feed` instead of `--input-appcast`; it records that
the feed was absent. For subsequent candidates always stage from the current live feed, not a prior
candidate's staged file. The stage output is immutable: choose a fresh directory for a respin.

Only after both App Store submissions have code approval and the final go decision, create the
post-approval `v{version}` tag and run `handoff` with the same artifact JSON. The handoff checks
that `v{version}`, `rc/{version}-b{repoBuild}`, and the artifact's commit SHA are identical before
calling `gh`; it creates a new draft release and uploads the exact `KeeForge-{version}-b{repoBuild}.zip`
once. If a prior run already created the draft, only that exact draft is resumed: an absent asset
is uploaded once, while a present asset is downloaded through `gh api` and verified without
clobbering. A draft release is not a public URL, so after publishing the release run
manually/explicitly in GitHub (there is no script invocation for this promotion), run the
unauthenticated `verify-public-url` and retain its SHA/size evidence. Then invoke `publish-appcast` with the staged
metadata, public evidence, and explicit deployment destination. Publication uses an atomic
compare-and-swap against the base appcast hash, so a concurrent feed change aborts. Never use
`--clobber`, replace a mismatched release/asset, or publish a feed without final public URL
verification.

The final two commands are explicit and must be run only after the draft release is published:

```bash
ci_scripts/release_direct_artifact.sh verify-public-url \
  --artifact-json build/mac-direct/direct-artifact.json \
  --output scratch/direct-release/public-verification.json
ci_scripts/release_direct_artifact.sh publish-appcast \
  --staged scratch/direct-release/appcast.xml \
  --metadata scratch/direct-release/staged-appcast.json \
  --public-verification scratch/direct-release/public-verification.json \
  --destination /path/to/deployed/appcast.xml
```

Use `verify-live-feed --metadata scratch/direct-release/staged-appcast.json --url https://keeforge.com/appcast.xml --output scratch/direct-release/live-feed.json` before publication (expects the recorded base SHA) and after publication (expects the staged SHA). The website source is `keeforge.com/public/appcast.xml`; Pages deploys when its reviewed source change is pushed, then the Worker serves it at `/appcast.xml`.

The publication command records an explicit absent base when staging a first feed; for later
releases, it requires the destination's current bytes to match the staged base SHA immediately
before an atomic rename. It will not overwrite an unrelated or concurrently changed feed.

For a safe offline rehearsal (the normal test path):

```bash
ci_scripts/release_direct_artifact.sh --fixture "$(mktemp -d)"
```

Each new item's `sparkle:releaseNotesLink` is the version's GitHub release page,
`https://github.com/KeeForge/KeeForge/releases/tag/v{version}`. The fixture keeps an older item,
checks that link, creates a deterministic zip, validates its hash/size, verifies the
local download through the same byte-check abstraction used for GitHub assets, exercises duplicate
and base-mismatch refusal, and atomically publishes against a matching local base. It does not
invoke `gh`, `curl`, `xcodebuild`, `notarytool`, tags, pushes, or ASC.

## KDBX Compatibility Gate

1. Run `-only-testing:KeeForgeTests/KDBXCompatibilityTests` (or `KeeForgeMacTests/KDBXCompatibilityTests` under `KDBX_COMPAT_SCHEME=KeeForgeMac` — the Mac test target compiles the same sources). The matrix suite writes each scenario's `.kdbx` bytes as an XCTAttachment on the way past its own assertions — there is no separate artifact-only test re-running the (Argon2-expensive) scenarios.
2. `xcrun xcresulttool export attachments` dumps the attachments. Exported file names are mangled to UUIDs, so the script maps them back through xcresulttool's own `manifest.json` index (`suggestedHumanReadableName` → `exportedFileName`). That mapping is load-bearing; do not simplify it away.
3. Collect the **manifest fragments**. Each emitting test method attaches one, so the script finds them by content — any exported file that parses as a JSON object with an `"artifacts"` key — rather than by name. Fragments are merged and deduped by artifact id; conflicting copies of the same id, zero fragments found, or any id in `expectedArtifactIDs` that no method emitted all fail the gate.
4. Verify each merged artifact with `keepassxc-cli`:
   - `search` for every `expectedSearchTerms` entry, `ls` for every `expectedGroupPaths` entry.
   - `attachment-export` plus a SHA-256 comparison for every `expectedAttachments` entry (the `kitchen-sink.kdbx`- and `unknown-inner-header.kdbx`-derived artifacts).
   - `show -s -a Password` for every `expectedPasswords` entry. This is the only check that decrypts anything: searching and listing only read plaintext XML, so without it a protected-value stream that is self-consistent but non-conforming would pass the whole gate. Every fixture-smoke artifact verifies both a password KeeForge just wrote and one the fixture already carried (authored by another KeePass implementation), covering AES, ChaCha20, Twofish, key-file, KDBX 4.1, unknown-XML, unknown-inner-header, high-iteration Argon2 (1500 x 1 MiB), and attachment databases; the rich `create-entry`/`update-entry` artifacts cover a created and an edited password.
   - `show -t` (TOTP) for every `expectedTOTPs` entry, proving real KeePassXC *generates a code* from what KeeForge enrolled — `update-entry` carries the fresh-enrollment verbatim `otp` URI (the entry editor's primary output) and `create-entry` the `TimeOtp-*` authoring path. The expected code is recomputed by an independent RFC 6238 reference implementation inside the gate script for the time windows in effect just before and just after the CLI call, and either is accepted — the call takes well under one period, so a 30-second window rollover mid-check can never flake the gate.
   Entry paths are resolved by exact-title `search` hit (and cached), so entries that moved into the Recycle Bin or were renamed by the edit still resolve.
5. On success the script prints the artifact count, attachment-check count, protected-password-check count, and TOTP-check count; zero TOTP checks fails the gate even if everything else passed.

The artifact set includes a Twofish-256-CBC database, providing an external KeePassXC opener check for KeeForge's cipher-preserving output. It also includes `merge-remote-divergence`, the output of a record-level merge (`KDBXMerger`): real KeePassXC must open it, list the group the merge grafted in from the other side, and decrypt the protected values it carried across. The KeeOTP artifact retains all raw source variants for the XCTest compatibility matrix, but probes a standard entry externally because KeePassXC 2.7.12 does not expose those KeeOTP fields through its XML reader/search path.

The artifact set itself is declared in `KeeForgeTests/KDBXCompatibilitySupport.swift` (`artifactDescriptors`) and emitted by `KeeForgeTests/KDBXCompatibilityTests.swift`; see `KeeForgeTests/AGENTS.md` for how to add one.

## Guidance

- Keep these scripts deterministic and noninteractive.
- If CI needs new generated files or dependencies, add them here instead of assuming the checked-in `.xcodeproj` is current.
- `Configs/BuildConfig.xcconfig` is a checked-in include file, not a generated source of truth. It lives in `Configs/` (not the repo root) so XcodeGen wraps it in a stable `Configs` group instead of one named after the checkout directory.
- Local developers should copy `BuildConfig.local.example.xcconfig` to `BuildConfig.local.xcconfig` (both at the repo root), fill in `DROPBOX_APP_KEY`, and optionally add `ONEDRIVE_CLIENT_ID` to test OneDrive OAuth.
- Xcode Cloud **must** provide `DROPBOX_APP_KEY` and `ONEDRIVE_CLIENT_ID` as environment variables on any workflow with an archive action. That is the **Tests (RC)** workflow on `rc/*` tags, whose archive action runs alongside its test action — no workflow triggers on `v*` (see `.agents/skills/release/xcode-cloud-setup.md`). For non-archive actions `ci_post_clone.sh` falls back to CI-only placeholders so project generation still succeeds. An archive (or a run with `REQUIRE_REAL_CLOUD_KEYS=1`) whose `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID` is missing or still a placeholder fails the build instead of shipping non-working cloud sign-in. Outside archives, `ONEDRIVE_CLIENT_ID` stays optional — the app just disables OneDrive sign-in.
- GitHub Actions can keep using simulator-safe placeholder values to materialize `BuildConfig.local.xcconfig`; the app treats the CI placeholders as cloud providers disabled for real sign-in.
- The Dropbox key is interpolated into the `db-$(DROPBOX_APP_KEY)` `CFBundleURLScheme`, so the CI placeholder is `ciplaceholderdropboxappkey`. Placeholders must be RFC1738-legal (alphanumerics only) — App Store Connect rejects underscores in URL schemes (ITMS-90158). `prepare_build_config.sh` also recognizes the legacy literal `CI_PLACEHOLDER_DROPBOX_APP_KEY` as a placeholder (`LEGACY_CI_PLACEHOLDER_DROPBOX_APP_KEY`). `KeeForgeTests/URLSchemeFormatTests.swift` enforces this on the built app bundle.

## macOS Distribution Channels

### Direct-build safety contract

`build_mac_direct.sh` uses `build/mac-direct` when no output argument is given. An
explicit output must be an absolute path naming a safe basename in exactly one
level below `${repo}/build`; relative paths, the build directory itself,
traversal, symlinks, and paths outside that directory are refused before any
cleanup. The source worktree must be clean, including untracked non-ignored
files, because XcodeGen uses folder globs; ignored `build/` and `scratch/`
outputs remain allowed. Before direct generation, the script saves the exact
`Package.resolved` bytes (or records that it was absent), installs its EXIT
restoration trap, runs normal XcodeGen on exit, restores that saved state, and
only then removes its validated temporary state directory. Restoration failures
are reported and cannot turn a failed build into a success. Use
`ci_scripts/build_mac_direct.sh --preflight` to exercise these checks without
Xcode, notarization, network access, or keychain access.

KeeForge for Mac ships through two channels from one target. Which one you get is decided at project-generation time, not at build time:

- `xcodegen generate` — **Mac App Store**. No Sparkle in the binary at all and a StoreKit tip jar. Universal purchase with iOS is intended after the one-time App Store Connect Mac setup; it is not current ASC state. This is the default, so every existing workflow and every CI job produces the App Store build.
- `xcodegen generate --spec project-direct.yml` — **Developer ID direct download**. Links Sparkle, compiles with `KEEFORGE_DIRECT_DOWNLOAD`, swaps the tip jar for a GitHub Sponsors link, and never calls StoreKit. Driven by `build_mac_direct.sh`; you should not need to run it by hand.

Two specs rather than two targets because both channels must ship an app called `KeeForge.app` — the executable name is baked into the code signature, so it cannot be renamed afterwards — and two targets declaring the same product path is a hard Xcode error ("Multiple commands produce …/KeeForge.app"). Separate specs also make the channels mutually exclusive by construction, which is the property that matters: an App Store build must never contain an updater.

`DistributionChannel` (`KeeForge/Services/AppSupport/DistributionChannel.swift`) is the single runtime read of that condition; `DistributionChannelTests` fails if the two channels ever stop being mutually exclusive, or if the unit suites' test host turns out to be a direct build.

For the package-4 artifact gate and every release candidate, obtain the exact MAS `.app` by
exporting the accepted Xcode Cloud MAS archive; do not rebuild it. Before any external distribution
or direct-artifact staging, run the verifier against that MAS app and the exact exported direct app:

```bash
ci_scripts/verify_mac_artifact.sh --channel mas --app <exact-exported-mas-app> \
  --architectures arm64,x86_64 --expect-version {version} --expect-build {macTestFlightBuild}
ci_scripts/verify_mac_artifact.sh --channel direct --app <exact-direct-app> \
  --architectures arm64,x86_64 --expect-version {version} --expect-build {repoBuild}
```

Both must report `result=pass`. The MAS invocation must report `sparkle_present=false`, empty
feed/key presence; the direct invocation must report Sparkle, an HTTPS feed, and a present public
key while reporting no StoreKit. The direct invocation must also report
`installer_launcher_service=true`; the MAS invocation must report it false. The architecture argument is intentional: use universal
`arm64,x86_64` unless an explicit product decision records a different set before continuing.
