---
name: release
description: >
  Create a new release candidate for the KeeForge iOS app. Bumps the version in project.yml,
  updates CHANGELOG.md, runs the local KDBX compatibility gate, commits, and pushes an
  rc/{version} tag so Xcode Cloud and the iOS 18 GitHub Actions workflow run the full test suite;
  once both gates pass or any test failures pass an exact local-device reproduction, atomically
  promotes the RC tag to v{version} to trigger the Xcode Cloud build-and-archive workflow.
  Use this skill whenever the user wants to cut a release, create a release candidate,
  bump the version, ship a new version, or prepare a build for TestFlight/App Store.
  Triggers on phrases like "release", "new version", "bump version", "cut a release",
  "prepare release", "ship it", "release candidate", or "push a new build".
---

# Release Candidate Workflow

Create a new release candidate for the KeeForge iOS app. This is a sequential, high-stakes
workflow: each step depends on the previous one succeeding. Do not skip steps or proceed
past a failure.

Test execution model: the full unit and UI suites run on **Xcode Cloud** and **GitHub Actions**.
Do not run them locally up front. Run focused local XCTest reproductions only when a cloud test
fails. The release is gated in two tag stages:

1. `rc/{version}` tag → Xcode Cloud **"Tests (RC)"** and GitHub Actions
   **"iOS 18 RC Tests"** workflows (test-only, all suites).
2. Promote the successful `rc/{version}` tag to `v{version}` only after both test gates are
   accepted. The `v{version}` tag triggers Xcode Cloud's **"Release"** workflow (archive-only).
   Never promote a commit that the two RC workflows did not test.

Both gates are monitored from the command line with `gh` — Xcode Cloud reports into GitHub as a
check run on the RC commit, so App Store Connect is not needed to watch a run or read its
failures. See Step 7.

The KDBX compatibility gate always runs locally because Xcode Cloud does not install KeePassXC.

## Usage

The user invokes this skill with a version number:

```
/release 1.6.0
```

If no version is provided, read the current `MARKETING_VERSION` from `project.yml` and
suggest the next minor bump (e.g. 1.5.0 to 1.6.0). Ask the user to confirm before proceeding.

## Step 1: Validate the repo state and version number

1. Verify the git state is releasable:
   - On the `main` branch (`git branch --show-current`).
   - Clean working tree (`git status --porcelain` is empty).
   - Up to date with the remote: run `git fetch origin --tags`, then confirm `main` is not behind `origin/main`.
2. Read `project.yml` and extract the current `MARKETING_VERSION` (from the KeeForge target).
3. Run `git tag --list 'v*'` and `git tag --list 'rc/*'` to get all existing release and RC tags
   (the fetch above pulled remote tags too — Xcode Cloud triggers on the remote tag, so a
   remote-only duplicate is just as fatal as a local one).
4. Verify:
   - The tag `v{version}` does not already exist.
   - The version is a valid semver (MAJOR.MINOR.PATCH).
   - The new version is greater than the current `MARKETING_VERSION`.
   - Note any existing `rc/{version}` or `rc/{version}-N` tags: they mean an earlier attempt at
     this release. That is not fatal (the next RC tag gets the next `-N` suffix in Step 6), but
     surface it to the user.
5. If any check fails, explain the problem and ask the user how to proceed (e.g. a corrected version). Do not proceed until validation passes.

**Resume exception:** if the working tree is dirty but the only changes are this release's own
edits (`project.yml`, `CHANGELOG.md`, `KeeForge.xcodeproj`,
`KeeForge/Services/AppSupport/WhatsNewPresentationService.swift`, and
`KeeForge/Resources/Localizable.xcstrings` already showing the expected new version/content), a
previous run of this skill likely stopped at a gate failure. Confirm with the user, then resume
from Step 5 instead of redoing Steps 2-4 or demanding a reset. Similarly, if the release commit
is already pushed and an `rc/{version}` tag exists, record that exact tag as the active RC tag and
resume from Step 7 rather than recreating the commit.

## Step 2: Update CHANGELOG.md

1. Read `CHANGELOG.md`.
2. Find the `## Unreleased` section and collect all entries beneath it (up to the next `## v` heading). Entries may be flat bullets, already grouped under `###` subsections, or a mix.
3. If the Unreleased section is empty, warn the user and ask whether to proceed with an empty changelog entry.
4. Organize the unreleased entries into categorized subsections. Keep entries that are already under a matching subsection where they are; review each remaining bullet and classify it:
   - **New Features** - new user-facing capabilities
   - **Fixes** - bug fixes (entries starting with "Fixed" or describing a fix)
   - **Security** - security-related changes
   - **Known Issues** - known problems or limitations
   - **Changes** - refactors, renames, internal improvements, infrastructure, test changes
   Only include subsections that have entries. Keep the original wording of each bullet.
5. Replace the Unreleased entries with the new versioned section. The result should look like:

```markdown
## Unreleased

## v{version} ({YYYY-MM-DD})

### New Features
- ...

### Fixes
- ...
```

The `## Unreleased` heading stays, but its content moves to the new version section.
Use today's date for the release date — get it from `date +%F`, don't guess.

## Step 3: Review and fix What's New content

Perform this review for every release, even if the content already looks complete:

1. Review the new version's `### New Features` and `### Fixes` bullets in `CHANGELOG.md` as
   source material. Generally keep the sheet to at most three items: prioritize the most important
   user-facing features, then use any remaining slots for notable bug fixes. A fix is notable when
   it materially improves a common workflow, prevents a crash or data-loss risk, or delivers a
   broad reliability improvement. Exclude routine polish, security hardening, known issues, and
   internal changes. If there are no eligible items, confirm that `WhatsNewCatalog` has no case for
   this version and continue without an empty sheet. Confirm with the user if the proposal looks
   good before proceeding.
2. Inspect the matching version case in
   `KeeForge/Services/AppSupport/WhatsNewPresentationService.swift`. Add it if needed, or fix it
   when it is stale, incomplete, overly technical, or inaccurate.
3. Rewrite each included feature as short, benefit-led copy for ordinary users. Do not copy issue
   numbers, implementation details, test coverage, internal terminology, or raw changelog prose.
4. Check platform accuracy. Keep features available on both iOS and macOS shared; set the
   `platforms` argument for features available on only one platform. Never advertise an iOS-only
   feature in the Mac sheet or vice versa.
5. Add or update every affected key and its German translation in
   `KeeForge/Resources/Localizable.xcstrings`. The localization tests in the Xcode Cloud RC run
   (Step 7) are the gate.
6. Re-read the completed sheet content as a user. Fix unclear titles, repetitive descriptions,
   missing major features, or claims that are not supported by the release.

Do not proceed until the catalog either has polished, accurate content for the new version or has
been deliberately omitted because the release contains no eligible user-facing highlights.

## Step 4: Update project.yml

Update **both** the `KeeForge` and `KeeForgeAutoFill` targets:

1. Set `MARKETING_VERSION` to the new version string (e.g. `"1.6.0"`).
2. Reset `CURRENT_PROJECT_VERSION` to `"1"`.

Both targets must always have identical version values. Use precise string-replacement edits
for these changes. There are exactly 4 values to update: 2 `MARKETING_VERSION`
values and 2 `CURRENT_PROJECT_VERSION` values.

## Step 5: Regenerate the Xcode project and run the local KDBX gate

Since `project.yml` changed, regenerate the `.xcodeproj` before building:

```bash
xcodegen generate
```

Do **not** run the full unit or UI test suites locally up front — both cloud systems run them in
Step 7. Local XCTest runs are allowed there only to adjudicate specific failed cloud tests.

Run the KDBX compatibility gate in a fresh `bash` session. This is a required local release
gate — Xcode Cloud does not install KeePassXC, so the release machine is the only place
KeeForge-produced databases get cross-validated against another KeePass implementation:

```bash
ci_scripts/run_kdbx_compatibility_gate.sh
```

If `keepassxc-cli` is not installed, stop and ask the user to install KeePassXC (or point
`KEEPASSXC_CLI` at the binary). Do not skip this gate or proceed past a gate failure.

## Step 6: Commit, push, and tag the release candidate

Only reach this step if the KDBX gate passed.

1. Stage the changed files (the `.xcodeproj` is tracked and changes when `xcodegen generate` runs):
   ```bash
   git add project.yml CHANGELOG.md KeeForge.xcodeproj \
     KeeForge/Services/AppSupport/WhatsNewPresentationService.swift \
     KeeForge/Resources/Localizable.xcstrings
   ```
2. Commit with message: `Release candidate v{version}`
3. Push the commit:
   ```bash
   git push origin main
   ```
4. Create and push the RC tag. This triggers both the Xcode Cloud **"Tests (RC)"** workflow and
   `.github/workflows/ios18-rc-tests.yml` on GitHub Actions (test-only, no archive):
   ```bash
   git tag -a rc/{version} -m "RC for v{version}"
   git push origin rc/{version}
   ```
   If `rc/{version}` already exists from an earlier attempt, use the next attempt suffix
   instead: `rc/{version}-2`, then `rc/{version}-3`, and so on. Never delete or force-move an
   existing tag — a re-pushed same-name tag does not reliably retrigger Xcode Cloud.

## Step 7: Wait for both RC test workflows

The RC tag push starts two independent full-suite runs. Do not promote the tag until both runs
reach a terminal state, and verify both runs tested the commit pointed to by the active RC tag.

1. Monitor Xcode Cloud **through GitHub**, not App Store Connect. Xcode Cloud mirrors the
   **"Tests (RC)"** workflow onto the RC commit as a check run (`KeeForge | Tests (RC) | Test - iOS`)
   and a commit status, so the whole gate is readable with `gh` and needs no ASC session:

   ```bash
   gh api repos/KeeForge/KeeForge/commits/{rc-sha}/check-runs \
     --jq '.check_runs[] | select(.app.name=="Xcode Cloud") | "\(.name) | \(.status) | \(.conclusion // "-")"'
   ```

   Poll that until `status` is `completed`. Interpreting `conclusion`:
   - `success` — gate is green.
   - `action_required` — Xcode Cloud's conclusion for a run with **test failures**. Read
     `.output.title` / `.output.summary` / `.output.text` from the same check run for the failure
     count and each failed test identifier with its assertion message. Check `Errors` in the
     summary table: `Errors|0` with `Test Failures|N` means genuine XCTest failures (the local
     reproduction in 7.4 applies); a nonzero `Errors` is a build/infrastructure failure (7.5).

   The commit status also carries the ASC build URL in `target_url`
   (`gh api repos/KeeForge/KeeForge/commits/{rc-sha}/status`), which is the fastest way to hand the
   user a link. The gate covers the **Test - iOS action on every destination**.

   Only fall back to asking the user to read App Store Connect for information the check run does
   not expose — in practice that is just the **per-destination device and iOS version** needed by
   Step 7.4. The failure list itself is always available from `gh`.
2. Monitor GitHub Actions workflow `.github/workflows/ios18-rc-tests.yml` (**"iOS 18 RC Tests"**).
   Prefer `gh run list --workflow ios18-rc-tests.yml --event push` to find the run whose
   `headBranch` is the active RC tag and whose `headSha` is the RC commit, then use
   `gh run watch <run-id> --exit-status`. The `ios18-tests` job must complete successfully.
3. Record each run's URL, commit SHA, status, and conclusion. Both must target the RC commit. A
   gate is accepted when it is green or when every actual XCTest failure from that gate passes
   the exact local reproduction below.
4. If either run reports XCTest failures, wait for the other run to finish too, then validate
   every failed test locally:
   - Read the cloud logs or result bundle and record each failed test identifier plus its simulator
     device type and exact iOS runtime version. For GitHub Actions, get the chosen iOS 18 runtime
     from the **Create iOS 18 simulator** log; its device is iPhone SE (3rd generation). For Xcode
     Cloud, get the device and OS from each failed test destination.
   - Confirm the same runtime is installed locally with `xcrun simctl list runtimes` and the same
     device type is available with `xcrun simctl list devicetypes`. Install the exact runtime or
     stop if the device/OS pair cannot be reproduced; do not substitute `OS=latest`.
   - In a fresh `bash` session, regenerate the project and run only the failed identifiers on each
     matching device/OS pair. Always include at least one `-only-testing:` selector:

     ```bash
     xcodegen generate
     xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
       -destination 'platform=iOS Simulator,name={exact device},OS={exact version}' \
       -only-testing:{test-target/test-class/test-method} > repro.log 2>&1
     echo "exit: $?"
     grep -E '\*\* TEST (SUCCEEDED|FAILED)' repro.log
     grep -E '^Test Case .*(passed|failed)' repro.log
     ```

     Redirect to a file and read the verdict back; do **not** pipe `xcodebuild` into `tail`/`head`.
     A pipeline reports the *last* command's exit status, so `xcodebuild ... | tail -40` returns 0
     even when the tests failed, and `-quiet` additionally suppresses the per-test `Test Case ...
     passed/failed` lines — together they can look exactly like a clean pass. A run is only a pass
     when you have seen `** TEST SUCCEEDED **` and a `passed` line for every identifier you selected.

     Verify the device/OS pair actually exists locally before trusting a run: an unmatched
     `-destination` makes `xcodebuild` print the list of available destinations and exit without
     running anything, which is easy to misread as success.

     Use separate commands when failures came from different device/OS pairs. Preserve the local
     commands and results in the release handoff.
   - If every failed cloud test passes locally on its exact device/OS pair, classify those cloud
     failures as CI-only flakes and accept that gate. Proceed once the other gate is also accepted.
   - If any failed test also fails locally, stop. Diagnose and fix it on `main` as a new commit
     (never amend or force-push the release commit), push a new RC tag (`rc/{version}-2`, `-3`, ...),
     and repeat Step 7 for both workflows.
5. A build, configuration, infrastructure, cancellation, or "tests did not run" failure is not an
   XCTest failure and cannot be overridden by a local pass. Rerun that workflow on the same RC
   commit, or fix the cause and cut a new RC. Do not proceed until both gates are accepted.

## Step 8: Promote the RC tag to the official version

Only after both Step 7 gates are accepted. The active RC tag may be `rc/{version}` or a suffixed
retry such as `rc/{version}-2`.

1. Fetch and confirm local `main`, `origin/main`, and the active RC tag all resolve to the exact
   commit tested by both workflows. If commits landed on `main` in between, go back to Step 6 and
   cut a new RC; never release an untested commit.
2. Create the annotated official tag at that exact commit. Git has no native tag-rename command,
   so promote the remote tag with one atomic ref update: add `v{version}` and delete the active RC
   tag in the same push. This leaves no state where the remote has only one half of the rename and
   triggers Xcode Cloud's archive-only **"Release"** workflow.

   ```bash
   git fetch origin --tags
   rc_tag='rc/{version}' # use the actual successful tag, including any retry suffix
   rc_commit=$(git rev-list -n1 "$rc_tag")
   test "$(git rev-parse main)" = "$rc_commit"
   test "$(git rev-parse origin/main)" = "$rc_commit"
   git tag -a 'v{version}' -m 'Release v{version}' "$rc_commit"
   git push --atomic origin 'refs/tags/v{version}' ":refs/tags/$rc_tag"
   git tag -d "$rc_tag"
   ```

   Never force-push either tag. If the atomic push fails, the remote refs remain unchanged; stop
   and diagnose before retrying.

   If `git fetch origin --tags` reports `! [rejected] ... (would clobber existing tag)` it also
   exits nonzero, which aborts this block under `set -e` before a single check runs. That means a
   local tag has drifted from the remote; the remote is authoritative for released tags. Inspect
   both sides, then realign the local tag with `git fetch origin --tags --force` rather than
   working around the exit code.
3. Verify the remote contains `v{version}`, no longer contains the promoted RC tag, and that
   `v{version}^{}` resolves to the recorded RC commit. Earlier failed, suffixed RC-attempt tags may
   remain for audit history.

After promotion, confirm success and remind the user that Xcode Cloud will pick up the
`v{version}` tag and start the build, TestFlight, and App Store Review pipeline.
