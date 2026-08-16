# Adjudicating a Failed RC Gate

Read this when either RC gate in step A8 is not green. Both gates must be **accepted** before a
candidate build is distributed to external testers. A gate is accepted when it is green, or when
every actual XCTest failure from that gate passes an exact local reproduction.

Wait for both runs to reach a terminal state before adjudicating either one. Do not distribute a
build with an unresolved gate.

## Reading the Xcode Cloud gate

Xcode Cloud reports into GitHub as a check run on the RC commit, so the whole gate is readable
with `gh` and needs no App Store Connect session — use the A8 `gh api .../check-runs` command.

Poll until `status` is `completed`. Interpreting `conclusion`:

- `success` — gate is green.
- `action_required` — Xcode Cloud's conclusion for a run with **test failures**. Read
  `.output.title` / `.output.summary` / `.output.text` from the same check run for the failure
  count and each failed test identifier with its assertion message.

Check the `Errors` column in the summary table:

- `Errors|0` with `Test Failures|N` — genuine XCTest failures. The local reproduction below applies.
- Nonzero `Errors` — a build or infrastructure failure. See "Non-test failures" below.

The commit status also carries the App Store Connect build URL in `target_url`, which is the
fastest way to hand the user a link:

```bash
gh api repos/KeeForge/KeeForge/commits/{rc-sha}/status
```

The gate covers the **Test - iOS action on every destination**. Only fall back to asking the user
to read App Store Connect for information the check run does not expose — in practice that is just
the per-destination device and iOS version. The failure list itself is always available from `gh`.

## Reading the GitHub Actions gate

Use the A8 `gh run list` / `gh run watch` commands. Match the run whose `headBranch` is the active
RC tag and whose `headSha` is the RC commit. The `ios18-tests` job must complete successfully.

This workflow runs the full unit + UI suites on an iPhone SE (3rd generation) at the minimum
supported iOS 18 runtime, then a regular-width lane on an iPad (10th generation) for the two
iPad-only UI classes. Those iPad classes `XCTSkip` on every other CI destination, so this is the
only place they execute.

## Reproducing a test failure locally

Every failed test must be reproduced on its **exact** device and OS pair. `OS=latest` is not a
substitute and a near-miss destination proves nothing.

1. Record each failed test identifier plus its simulator device type and exact iOS runtime version.
   - **GitHub Actions**: the chosen iOS 18 runtime is in the *Create iOS 18 simulators* log step;
     the device is iPhone SE (3rd generation), or iPad (10th generation) for the regular-width lane.
   - **Xcode Cloud**: read the device and OS from each failed test destination.
2. Confirm the runtime is installed locally with `xcrun simctl list runtimes` and the device type
   is available with `xcrun simctl list devicetypes`. Install the exact runtime, or stop if the
   pair cannot be reproduced.
3. In a fresh `bash` session, under the repo's Xcode lock, regenerate the project and run only the
   failed identifiers on each matching device/OS pair:

```bash
xcodegen generate
LOG=/Users/tan/src/KeeForge/scratch/xcode-logs/$(date +%Y%m%d-%H%M%S)-repro.log
mkdir -p "$(dirname "$LOG")"
/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- \
  xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
    -destination 'platform=iOS Simulator,name={exact device},OS={exact version}' \
    -only-testing:{test-target/test-class/test-method} > "$LOG" 2>&1
echo "exit=$? log=$LOG"
grep -E '\*\* TEST (SUCCEEDED|FAILED)' "$LOG"
grep -E '^Test Case .*(passed|failed)' "$LOG"
```

Always include at least one `-only-testing:` selector, and use separate commands when failures
came from different device/OS pairs.

### Do not misread a pass

- Redirect to a log file and read the verdict back. Never pipe `xcodebuild` into `tail`/`head`: a
  pipeline reports the *last* command's exit status, so `xcodebuild ... | tail -40` returns 0 even
  when the tests failed.
- Keep `-quiet` off. It suppresses exactly the per-test `Test Case ... passed/failed` lines you
  need, and combined with a pipe it can look identical to a clean pass.
- A run is a pass only when you have seen `** TEST SUCCEEDED **` **and** a `passed` line for every
  identifier you selected.
- Verify the device/OS pair exists locally before trusting a run. An unmatched `-destination`
  makes `xcodebuild` print the list of available destinations and exit without running anything,
  which is easy to misread as success.

## Verdicts

**Every failed cloud test passes locally on its exact pair** → classify those cloud failures as
CI-only flakes and accept that gate. Record the local commands and results in the release handoff.
Proceed once the other gate is also accepted.

Do **not** respin for an accepted flake. Xcode Cloud's archive action runs in parallel with its
test action, so a red test action still produces and uploads a build — that build is the one you
just adjudicated, and a respin would throw it away and burn a build number for nothing. Its
`TestFlight External Testing` post-action will show *Did Not Run*, because post-actions are skipped
on a failed build, so distribution is manual: find the build in App Store Connect under TestFlight
and distribute it to the public-link group as usual (A9). Confirm the `{version} ({build})` pair
matches the candidate you adjudicated before distributing.

**Any failed test also fails locally** → stop. Fix it as a new commit on the release branch, then
run Mode B: bump the build number, re-run the KDBX gate, push the next `rc/{version}-b{build}` tag,
and repeat A8 for both workflows. Never amend or force-push the release commit.

## Non-test failures

A build, configuration, infrastructure, cancellation, or "tests did not run" failure is **not** an
XCTest failure and cannot be overridden by a local pass. Rerun that workflow on the same RC commit,
or fix the cause and cut a new candidate build. Do not proceed until both gates are accepted.

An archive failure complaining about `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID` means the Xcode
Cloud workflow is missing its environment variables — this is deliberate
(`ci_scripts/ci_pre_xcodebuild.sh` fails an archive rather than shipping non-working cloud
sign-in). See `xcode-cloud-setup.md`.
