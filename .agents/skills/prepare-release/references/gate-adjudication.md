# Adjudicating a Failed RC Gate

Read this during [candidate gates](candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke) when any RC verdict is not green. [candidate gates](candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke) adjudicates four cloud verdicts plus
the two KDBX gates and the local Mac smoke; [production shipping](../../ship-release/SKILL.md) ships an already-accepted candidate and
does not reopen these decisions. Do not distribute either App Store build or call the direct build
release-ready while any required verdict is unresolved.

The candidate identity is the non-secret `manifest.json` in the candidate's
[release artifact directory](shared.md#where-release-artifacts-live). It maps one immutable
`rc/{version}-b{repoBuild}` tag and commit SHA to the iOS TestFlight build, Mac TestFlight build,
and direct `CFBundleVersion`. Record every verdict, reproduction, adjudication, and log path there.

## The cloud verdicts

Wait for all cloud runs to reach a terminal state before adjudicating any of them. A cloud verdict
is accepted only when it is green, or when every actual XCTest failure in that verdict passes the
exact local reproduction below. A local pass never overrides a build, configuration, infrastructure,
cancellation, or "tests did not run" failure.

### 1. Xcode Cloud `Tests (RC)` workflow

One `rc/*` tag starts the `Tests (RC)` workflow. It holds only the iOS and `KeeForgeMac` App Store
archive/upload actions and runs no tests; the hosted test gates are the `tests.yml` jobs below.
Inspect every Xcode Cloud check for the RC SHA and record the URLs/statuses in the manifest
(`gates.xcodeCloud`). Both archive actions must succeed before external distribution.
If the tag push produced no run, a manual branch run is acceptable only through the conditional
recovery in [xcode-cloud-setup.md](xcode-cloud-setup.md) ("Recovering a missing tag-triggered run"), with its full SHA
verified in the run Overview and recorded in the manifest. Reject any run whose SHA differs.

```bash
gh api repos/KeeForge/KeeForge/commits/{rc-sha}/check-runs \
  --jq '.check_runs[] | select(.app.name=="Xcode Cloud") | "\(.name) | \(.status) | \(.conclusion // "-") | \(.details_url // "-")"'
gh api repos/KeeForge/KeeForge/commits/{rc-sha}/status
```

Poll until each check is `completed`; only `success` is accepted. A failed or missing archive or a
failed upload is a non-test failure and blocks the candidate.

The archives finish while the GitHub tests run. Do not discard or distribute an uploaded build yet:
first adjudicate any test failures, accept all other gates, and then use the manifest's
affected-platform TestFlight build for its deliberate manual distribution.

### Canonical XCTest evidence

Read each uploaded `.xcresult` with `xcrun xcresulttool get test-results summary --path <bundle>
--compact`, not its trailing console summary. An automatic pass requires `result=Passed`, zero
failures, and at least one executed test; exit 65 is tolerated only with that evidence. If the
canonical summary reports failed XCTest identifiers, including under a green GitHub check, record
that summary and adjudicate those exact failures through the local reproductions below. A missing or
malformed bundle, no executed tests, or another nonzero `xcodebuild` exit is a non-test failure and
cannot be adjudicated.

### 2. macOS GitHub Actions job

Match the `tests.yml` run whose `headBranch` is the active RC tag and whose `headSha` is the RC
commit, and read its `macos-unit-tests` job:

```bash
gh run list --workflow tests.yml --event push
gh run view <run-id> --json jobs --jq '.jobs[] | select(.name=="macos-unit-tests") | "\(.status) \(.conclusion) \(.url)"'
```

This is the hosted Mac unit-suite verdict (`gates.githubMac`). `KeeForgeMacUITests` needs an unlocked active login
session and is covered by the required local `MacSmokeUITests` step, not by this headless workflow.
Record the run URL, SHA, status, and conclusion in the manifest.

### 3. iPhone GitHub Actions jobs

In the same `tests.yml` run, read the six `ios-rc-tests` jobs that run `KeeForgeCloudUnitTests`,
`KeeForgeCloudUIA`, and `KeeForgeCloudUIB` on iPhone 18 Pro and iPhone SE (3rd generation):

```bash
gh run view <run-id> --json jobs --jq '.jobs[] | select(.name|test("KeeForgeCloud")) | "\(.name) \(.status) \(.conclusion) \(.url)"'
```

Together they are the hosted iOS unit and UI verdict (`gates.githubIPhone`). Record every job URL,
the SHA, status, and conclusion. The iPhone Duo job in the same run is not a gate.

### 4. iPad GitHub Actions job

In the same `tests.yml` run, read the `ios-rc-tests / KeeForge (iPad (A16))` job:

```bash
gh run view <run-id> --json jobs --jq '.jobs[] | select(.name=="ios-rc-tests / KeeForge (iPad (A16))") | "\(.status) \(.conclusion) \(.url)"'
```

It runs `DatabaseCreationRegularWidthUITests` and `RegularWidthWorkspaceUITests`, which `XCTSkip`
on every compact-width device, so no other gate executes them. Record the job URL, SHA, status, and
conclusion as `gates.githubIPad`.

## The owner-run gates that also must be accepted

Run both KDBX compatibility gates for the same RC source tree, and record separate evidence as
`gates.kdbxIOS` and `gates.kdbxMac`. The commands, evidence names, and source-tree check are in
[KDBX gates](candidate.md#regenerate-and-run-the-kdbx-gates):

```bash
ci_scripts/run_kdbx_compatibility_gate.sh
KDBX_COMPAT_SCHEME=KeeForgeMac ci_scripts/run_kdbx_compatibility_gate.sh
```

Run `KeeForgeMacUITests/MacSmokeUITests` locally on an unlocked release Mac under the Xcode lock.
The four cloud verdicts, both KDBX gates, and this smoke suite must all be accepted before either
platform reaches external testers. Record the smoke result and result-bundle/log path in the
manifest.

## Exact local reproduction

Every actual XCTest failure must be reproduced on its exact platform/runtime. Use a fresh Bash
session, keep `-quiet` off, use at least one `-only-testing:` selector, capture the complete output
and result bundle in the candidate's `evidence/` directory (they are what the adjudication cites),
and run each Xcode command through:

```bash
scripts/with-repo-lock.sh xcode -- ...
```

### iOS failures

Record the failed identifier, simulator type, and exact iOS runtime. For a `tests.yml` `ios-rc-tests` job, the device is in the job name and the
runtime is in its `Create simulator` log step. Confirm both with `xcrun simctl list runtimes` and `xcrun simctl list devicetypes`; an
unavailable exact pair cannot be called a reproduction.

```bash
xcodegen generate
CANDIDATE="$(ci_scripts/release_dir.sh {version}-b{repoBuild})"
LOG="$CANDIDATE/evidence/repro-ios-{name}.log"
scripts/with-repo-lock.sh xcode -- \
  xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
    -destination 'platform=iOS Simulator,name={exact device},OS={exact version}' \
    -resultBundlePath "$CANDIDATE/evidence/repro-ios-{name}.xcresult" \
    -only-testing:{test-target/test-class/test-method} > "$LOG" 2>&1
echo "exit=$? log=$LOG"
grep -E '\*\* TEST (SUCCEEDED|FAILED)' "$LOG"
grep -E '^Test Case .*(passed|failed)' "$LOG"
```

### Mac failures

For a macOS GitHub Actions test failure, record the failed `KeeForgeMacTests` identifier.
The exact local reproduction uses the Mac scheme and macOS destination; do not use the iOS scheme,
an iOS simulator, or a broad test run:

```bash
xcodegen generate
CANDIDATE="$(ci_scripts/release_dir.sh {version}-b{repoBuild})"
LOG="$CANDIDATE/evidence/repro-mac-{name}.log"
scripts/with-repo-lock.sh xcode -- \
  xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
    -destination 'platform=macOS' \
    -resultBundlePath "$CANDIDATE/evidence/repro-mac-{name}.xcresult" \
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
manifest. Manual distribution may be used only after every cloud verdict, both KDBX gates, and
local Mac smoke are accepted: identify the affected platform's TestFlight build from the manifest
and match its marketing version, platform build number, RC tag, and commit SHA before distributing.
Proceed with the first Beta App Review action (when required) and each platform distribution when
the user has already authorized that named candidate action in the current task; otherwise obtain
action-time confirmation. That beta authorization never authorizes production release, App Review
submission, or legal declarations. Never use the newest build by default.

**Any failed test also fails locally** → stop. Fix it as a new commit on the shared release branch;
never amend or force-push the existing RC. Increment the global `repoBuild` on all five product
targets (`KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, `KeeForgeMacAutoFill`, and
`KeeForgeBrowserHost`), run both KDBX
gates again, rebuild all three artifacts (iOS, MAS, and direct Mac) from the new commit, and push
the immutable `rc/{version}-b{repoBuild}` tag. Repeat every cloud verdict, both KDBX gates,
local Mac smoke, artifact mapping, and any required soak.

## Owner exceptions for a hosted test gate

Only the owner can keep a candidate whose hosted test gate (`githubMac`, `githubIPhone`, or
`githubIPad`) is red and cannot be adjudicated above: a build failure on the tag's own workflow, or
an XCTest failure that also fails locally. State what each failure is and its user impact, and
obtain the owner's explicit acceptance for that gate before recording anything. Then set the gate's
`status` to `ownerException` with its real `verdict`, `failureKind`, run `url`, a `reason`, the
classified `failedTests`, and any supporting evidence, and add a root `ownerAcceptedExceptions`
entry naming the `gate` with the `decision`, `acceptedAt`, and `authorizedBy`. The validator accepts
the gate only with both records. Never record an excepted gate as passed. The Xcode Cloud archives,
both KDBX gates, the Mac smoke, and both artifact checks have no exception.

## Non-test failures always block

Without such an owner exception:


A build, signing, configuration, archive, upload, infrastructure, cancellation, or tests-not-run
failure cannot be overridden by a local pass. Rerun the affected workflow on the same RC SHA when
safe, or fix the cause and create a new candidate using the respin procedure above. Do not
distribute until every cloud verdict and all owner-run gates are accepted.

An archive failure complaining about `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID` means the Xcode
Cloud workflow is missing its environment variables. This is intentional:
`ci_scripts/ci_pre_xcodebuild.sh` blocks an archive rather than shipping broken cloud sign-in. See
[xcode-cloud-setup.md](xcode-cloud-setup.md).
