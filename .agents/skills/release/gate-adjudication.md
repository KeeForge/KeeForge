# Adjudicating a Failed RC Gate

Read this during A8 when any RC verdict is not green. A8 adjudicates three cloud verdicts plus
the two local KDBX gates and the local Mac smoke; Mode C ships an already-accepted candidate and
does not reopen these decisions. Do not distribute either App Store build or call the direct build
release-ready while any required verdict is unresolved.

The candidate identity is the non-secret manifest at
`scratch/release-manifests/{version}-b{repoBuild}.json`. It maps one immutable
`rc/{version}-b{repoBuild}` tag and commit SHA to the iOS TestFlight build, Mac TestFlight build,
and direct `CFBundleVersion`. Record every verdict, reproduction, adjudication, and log path there.

## The three cloud verdicts

Wait for all cloud runs to reach a terminal state before adjudicating any of them. A cloud verdict
is accepted only when it is green, or when every actual XCTest failure in that verdict passes the
exact local reproduction below. A local pass never overrides a build, configuration, infrastructure,
cancellation, or "tests did not run" failure.

### 1. Xcode Cloud `Tests (RC)` workflow

One `rc/*` tag starts the `Tests (RC)` workflow. It contains iOS and macOS test actions (both
**Required to Pass**) and iOS and `KeeForgeMac` App Store archive/upload actions. App Store Connect
may expose these as separate Xcode Cloud check runs or as one workflow summary; inspect every
Xcode Cloud check for the RC SHA and record the URLs/statuses in the manifest. Both platform test
actions and both archive actions must reach a terminal, accepted state before external distribution.

```bash
gh api repos/KeeForge/KeeForge/commits/{rc-sha}/check-runs \
  --jq '.check_runs[] | select(.app.name=="Xcode Cloud") | "\(.name) | \(.status) | \(.conclusion // "-") | \(.details_url // "-")"'
gh api repos/KeeForge/KeeForge/commits/{rc-sha}/status
```

Poll until each relevant check is `completed`. `success` is green. `action_required` may represent
actual XCTest failures; read the check's `.output.title`, `.output.summary`, and `.output.text` for
the failed identifiers and assertion messages. A nonzero `Errors` count, missing archive, failed
upload, or tests-not-run result is a non-test failure and blocks the candidate.

The Xcode Cloud test and archive actions run in parallel. A red test action can still leave an
uploaded platform build. Do not discard or distribute it yet: first adjudicate the exact test
failures, accept all other gates, and then use the manifest's affected-platform TestFlight build
for its deliberate manual distribution.

### 2. iOS 18 GitHub Actions workflow

Match the run whose `headBranch` is the active RC tag and whose `headSha` is the RC commit:

```bash
gh run list --workflow ios18-rc-tests.yml --event push
gh run watch <run-id> --exit-status
```

The `ios18-tests` job runs the full unit/UI suites on an iPhone SE (3rd generation) at the selected
iOS 18 runtime, then the regular-width iPad lane for the two iPad-only UI classes. Record the run
URL, SHA, status, and conclusion in the manifest.

### 3. macOS GitHub Actions workflow

Match the run whose `headBranch` is the active RC tag and whose `headSha` is the RC commit:

```bash
gh run list --workflow macos-rc-tests.yml --event push
gh run watch <run-id> --exit-status
```

This is the hosted Mac unit-suite verdict. `KeeForgeMacUITests` needs an unlocked active login
session and is covered by the required local `MacSmokeUITests` step, not by this headless workflow.
Record the run URL, SHA, status, and conclusion in the manifest.

## The local gates that also must be accepted

Run both KDBX compatibility gates for the same RC source tree, in fresh Bash sessions under the
repository Xcode lock, and record separate logs as `gates.kdbxIOS` and `gates.kdbxMac`:

```bash
ci_scripts/run_kdbx_compatibility_gate.sh
KDBX_COMPAT_SCHEME=KeeForgeMac ci_scripts/run_kdbx_compatibility_gate.sh
```

Run `KeeForgeMacUITests/MacSmokeUITests` locally on an unlocked release Mac under the Xcode lock.
The three cloud verdicts, both KDBX gates, and this smoke suite must all be accepted before either
platform reaches external testers. Record the smoke result and result-bundle/log path in the
manifest.

## Exact local reproduction

Every actual XCTest failure must be reproduced on its exact platform/runtime. Use a fresh Bash
session, keep `-quiet` off, use at least one `-only-testing:` selector, capture the complete output
to `/Users/tan/src/KeeForge/scratch/xcode-logs/`, and run each Xcode command through:

```bash
/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- ...
```

### iOS failures

Record the failed identifier, simulator type, and exact iOS runtime. For GitHub Actions, the iOS
18 runtime is in the `Create iOS 18 simulators` log step: iPhone SE (3rd generation), or iPad
(10th generation) for the regular-width lane. For Xcode Cloud, read the device/OS from the failed
destination. Confirm both with `xcrun simctl list runtimes` and `xcrun simctl list devicetypes`; an
unavailable exact pair cannot be called a reproduction.

```bash
xcodegen generate
LOG=/Users/tan/src/KeeForge/scratch/xcode-logs/$(date +%Y%m%d-%H%M%S)-ios-repro.log
mkdir -p "$(dirname "$LOG")"
/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- \
  xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
    -destination 'platform=iOS Simulator,name={exact device},OS={exact version}' \
    -only-testing:{test-target/test-class/test-method} > "$LOG" 2>&1
echo "exit=$? log=$LOG"
grep -E '\*\* TEST (SUCCEEDED|FAILED)' "$LOG"
grep -E '^Test Case .*(passed|failed)' "$LOG"
```

### Mac failures

For a macOS GitHub Actions or Xcode Cloud failure, record the failed `KeeForgeMacTests` identifier.
The exact local reproduction uses the Mac scheme and macOS destination; do not use the iOS scheme,
an iOS simulator, or a broad test run:

```bash
xcodegen generate
LOG=/Users/tan/src/KeeForge/scratch/xcode-logs/$(date +%Y%m%d-%H%M%S)-mac-repro.log
mkdir -p "$(dirname "$LOG")"
/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- \
  xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
    -destination 'platform=macOS' \
    -only-testing:KeeForgeMacTests/{test-class/test-method} > "$LOG" 2>&1
echo "exit=$? log=$LOG"
grep -E '\*\* TEST (SUCCEEDED|FAILED)' "$LOG"
grep -E '^Test Case .*(passed|failed)' "$LOG"
```

A run is a pass only after `** TEST SUCCEEDED **` and a `passed` line for every selected
identifier. An unmatched destination can exit without running tests; verify the destination exists
before trusting the output. For Mac UI smoke failures, reproduce the named smoke test locally on
the unlocked login session with the same scheme/selector and retain its result bundle.

## Verdicts and actions

**Every failed cloud test passes locally on its exact pair** → classify those failures as CI-only
flakes and accept that affected cloud verdict. Record the local command, result, and reason in the
manifest. Manual distribution may be used only after all three cloud verdicts, both KDBX gates, and
local Mac smoke are accepted: identify the affected platform's TestFlight build from the manifest
and match its marketing version, platform build number, RC tag, and commit SHA before distributing.
Obtain explicit action-time confirmation immediately before the first Beta App Review action (when
required) and immediately before distributing each platform. Never use the newest build by default.

**Any failed test also fails locally** → stop. Fix it as a new commit on the shared release branch;
never amend or force-push the existing RC. Increment the global `repoBuild` on all four product
targets (`KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, and `KeeForgeMacAutoFill`), run both KDBX
gates again, rebuild all three artifacts (iOS, MAS, and direct Mac) from the new commit, and push
the immutable `rc/{version}-b{repoBuild}` tag. Repeat all three cloud verdicts, both KDBX gates,
local Mac smoke, artifact mapping, and any required soak.

## Non-test failures always block

A build, signing, configuration, archive, upload, infrastructure, cancellation, or tests-not-run
failure cannot be overridden by a local pass. Rerun the affected workflow on the same RC SHA when
safe, or fix the cause and create a new candidate using the respin procedure above. Do not
distribute until all three cloud verdicts and all local gates are accepted.

An archive failure complaining about `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID` means the Xcode
Cloud workflow is missing its environment variables. This is intentional:
`ci_scripts/ci_pre_xcodebuild.sh` blocks an archive rather than shipping broken cloud sign-in. See
`xcode-cloud-setup.md`.
