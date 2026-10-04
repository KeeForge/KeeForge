# Shared release contract

Releases run on one dedicated `release/{major}.{minor}` branch. Each candidate produces three
artifacts from one commit: an iOS App Store/TestFlight build, a Mac App Store/TestFlight build,
and a notarized direct-download Mac build. Archives/uploads may be automatic, but the two App Store
builds are moved manually to their respective external TestFlight groups only after every required
gate is accepted; the direct build is staged and soaked separately. Ship only those exact artifacts.
This is a sequential, high-stakes workflow: each step depends on the previous one succeeding. Do not
skip steps or proceed past a failure.

Test execution model: the full unit suites and hosted UI suites run on **Xcode Cloud** and
**GitHub Actions**. `KeeForgeMacUITests/MacSmokeUITests` is the required local UI smoke because it
needs an unlocked active login session. Do not run the full hosted suites locally up front. Run
focused local XCTest reproductions only when a cloud test fails — see [gate-adjudication.md](gate-adjudication.md).

## Candidate owner readiness

Before starting a candidate, plan the owner-operated prerequisites while the owner is available:

- Run `automationmodetool` with no arguments. If it says enabling Automation Mode requires user
  authentication, schedule the [candidate gates](candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke) smoke while the owner is present; the runner prompts then and
  times out unanswered.
- Confirm whether the login Keychain access used by Sparkle `sign_update` during [artifact verification and beta distribution](candidate.md#verify-all-three-artifacts-assign-the-app-store-builds-and-distribute-when-approved) finalization
  needs owner authentication. Sign only the candidate's exact ZIP, and schedule finalization while
  the owner can approve that prompt. A respin creates a new ZIP and may need fresh Keychain approval.
- Check that the simulator runtime matching each hosted UI gate's exact iOS version and build is
  installed before declaring local reproduction unavailable. Preserve the `simctl list runtimes`
  output. A CLI `xcodebuild -downloadPlatform` catalog miss is not conclusive: use one native
  Xcode **Settings → Components → Other Installed Platforms → Add Platforms** catalog check before
  stopping. If that catalog offers the runtime, download and install it there, then verify the
  exact version/build with `simctl` before creating or using a simulator. Preserve the catalog and
  post-install diagnostics. Do not turn this into broad download or test retries.

Never disable authentication, broaden Keychain ACLs, or change security policy to bypass either
prompt. Never treat a smoke run that executed zero tests as a pass: it is an infrastructure failure.
Routine authorized test runs need no separate owner approval step.

## Shared release state and manifest

The release handoff is one state record, not a single build number:

`{version, repoBuild, rcTag, commitSHA, iosTestFlightBuild, macTestFlightBuild, directCFBundleVersion}`.

`repoBuild` is the globally monotonic `CURRENT_PROJECT_VERSION` in `project.yml`; it increases for
every minor, major, patch, and respin candidate and is identical on `KeeForge`,
`KeeForgeAutoFill`, `KeeForgeMac`, and `KeeForgeMacAutoFill`. It is never reset for a new marketing
version. The direct build's `CFBundleVersion` is this repo build. Set `repoBuild` from the
product-wide **Next Build Number** shown in App Store Connect under Xcode Cloud settings, after
verifying that it does not trail the repository floor. Xcode Cloud may still assign separate,
platform-specific TestFlight build numbers; record both and match each back to the RC tag and SHA
rather than assuming the uploaded records match the preflight value.

During a release, record the state in `scratch/release-manifests/{version}-b{repoBuild}.json`.
That path is gitignored and is working state, not a secret store. The manifest must contain only
non-secret evidence: `schemaVersion`, `version`, `repoBuild`, `rcTag`, `commitSHA`, `sourceTree`,
the App Store Connect build-number preflight, both platform build numbers/version records,
distribution timestamps and soak metrics, all gate verdicts/URLs or log paths, direct zip
filename/URL/SHA-256, Sparkle signature attributes, notarization ID, archive/symbol locations,
review states, release timestamps, and accepted soak exceptions. Never put passwords, tokens,
App Store Connect credentials, private signing keys, keychain profiles, or cloud secret values in
it or in logs. At ship time preserve the completed non-secret manifest with the release evidence
(for example, GitHub Release notes/asset or the team's secure release archive); the scratch copy is
not the long-term record.

A passed gate records its verdict and a log, URL, or result bundle. An adjudicated gate is only an
XCTest result: record `failureKind: "xctest"`, the failed test names, exact local reproductions, and
structured evidence. Infrastructure, archive, signing, and upload failures cannot be accepted by
adjudication. Any gate `commitSHA` or `sourceTree` recorded in the manifest must match the candidate.
Keep `platforms.*.reviewState` for beta state and add `platforms.*.appStoreReviewState` only for the
production code-approval state. A ship record also needs an accepted soak verdict with observed
metrics/evidence, or a documented owner-accepted exception.

## The four invariants

Violating any of these invalidates the release. They outrank convenience at every step, and
unlike the soak targets in [soak guidance](soak.md#candidate-soak) they are not judgement calls.

1. **Ship exactly what was soaked.** Select the iOS and Mac App Store builds from TestFlight and
   publish the staged direct zip; never re-archive or substitute a newer build after soaking.
2. **Every candidate has one globally increasing repo build and one immutable RC tag.** All four
   product targets carry that repo build. Xcode Cloud's iOS and Mac TestFlight numbers may differ
   from it and from each other, so the manifest maps all three artifacts to the same SHA.
3. **All gates are accepted before external distribution.** Accept the Xcode Cloud verdict, the
   iOS 18 GitHub Actions verdict, the macOS GitHub Actions verdict, both local KDBX gates, and the
   local Mac smoke suite; green or explicitly adjudicated per [gate-adjudication.md](gate-adjudication.md). Before
   external distribution or direct-artifact staging, both exact exported Mac apps must also pass
   `ci_scripts/verify_mac_artifact.sh` with universal `arm64,x86_64`, unless an explicit product
   decision records a different architecture set.
4. **Tags are immutable and `v{version}` is post-approval evidence.** Never delete, move, or
   force-push an `rc/*` tag. Create `v{version}` only after both App Store submissions have code
   approval and the final go decision; it triggers no build.

## Channel notes

- The macOS targets ship in lockstep with iOS: all four product targets carry the same
  `MARKETING_VERSION` and globally monotonic `CURRENT_PROJECT_VERSION`, bumped together in [release branch cut](new-release.md#commit-the-release-content-to-main-then-cut-the-branch)/[build-number selection](candidate.md#set-the-candidate-build-number)
  and every respin/patch.
- **One release branch covers both platforms.** `release/{major}.{minor}` is not per-platform, and
  neither is `rc/{version}-b{repoBuild}`: one candidate tag fires `ios18-rc-tests.yml`,
  `macos-rc-tests.yml`, and the Xcode Cloud RC workflow together, and the build they all test is
  the build both platforms ship. Splitting the branch would mean splitting the version numbers,
  which is the thing lockstep exists to prevent. A platform-specific fix still goes onto the shared
  release branch and respins one candidate for both.
- The two platforms diverge only at App Store Connect, which keeps a **separate version record,
  build, screenshot set, and review submission per platform**. Shipping is therefore not done when
  iOS is submitted; see the `publish-app-store-version` skill.
- The KDBX compatibility gate runs **per platform**. Run it for iOS as documented, then again with
  `KDBX_COMPAT_SCHEME=KeeForgeMac` (which switches the test target to `KeeForgeMacTests` and the
  destination to `platform=macOS`). Both must pass before external distribution, alongside all
  three cloud verdicts and local Mac smoke.
- The Mac ships through **two channels**. The Mac App Store build is the default
  (`xcodegen generate`) and is archived like the iOS app. The notarized
  Developer ID build is produced by `ci_scripts/build_mac_direct.sh`, which
  regenerates from the `project-direct.yml` overlay spec, archives, exports,
  restores the App Store project under the global Xcode lock, and then finalizes
  the checkpoint without that lock. It refuses to submit anything that is unsandboxed or carries a
  `com.apple.security.cs.*` exception, notarizes, staples, and emits the appcast
  zip and writes a non-secret `direct-artifact.json` handoff record. Run it **after** the App Store
  build is cut, from the same commit, so both channels ship identical code. Obtain/export the exact
  MAS app from the accepted Xcode Cloud archive without rebuilding, and run
  `ci_scripts/verify_mac_artifact.sh` on both exact exported apps with `--architectures arm64,x86_64`
  before external distribution or direct-artifact staging. A different architecture set requires
  an explicit product decision recorded in the manifest. Only after both checks pass, use
  `ci_scripts/release_direct_artifact.sh stage` to preserve older appcast items. After both App Store
  submissions have code approval and the final go decision, create `v{version}` and use that
  companion's `handoff` command: it verifies both local and origin tags resolve to the artifact SHA,
  creates a draft GitHub Release (or safely resumes the exact expected draft), uploads only an
  absent asset, and verifies the draft asset via the GitHub API. Manually/explicitly publish the
  already-verified draft release in GitHub (no script invocation), then run the unauthenticated
  `verify-public-url`; only its evidence permits the explicit `publish-appcast`
  compare-and-swap against the staged base feed. Publication is atomic and fails on a concurrent
  feed change.
  `build_mac_direct.sh` verifies the final ZIP's saved Sparkle signature against the exported app's
  embedded `SUPublicEDKey` before it writes `direct-artifact.json`; the check is Keychain-free and
  can be re-run with `ci_scripts/verify_sparkle_ed25519.swift APP ZIP SIGNATURE_FILE`.
  If archive/export restoration fails, preserve its pending checkpoint and output; it is not
  eligible for finalization or an automatic rebuild. If a direct build stops after notarization or signing, preserve its candidate output, exact ZIP,
  `notarization.json`, and `sparkle-signature.txt`; inspect and complete metadata/handoff manually.
  Do not re-run the full build into that directory.
- `KeeForgeMacUITests` cannot run on a headless runner — it needs an unlocked, active login session
  — so the Mac smoke suite stays a **local** pre-release step. `.github/workflows/macos-rc-tests.yml`
  covers the Mac unit suite on each `rc/*` tag.
- `ITSAppUsesNonExemptEncryption=false` is declared in both `KeeForge/Info.plist` and
  `KeeForgeMac/Info.plist`; ASC may resolve the build declaration from metadata, but the actual
  platform record must be verified. Any separate legal/documentation question remains independent
  and requires exact-question review plus action-time owner confirmation. If the app's cryptography
  changes materially, revisit the declaration rather than assuming it still applies.
