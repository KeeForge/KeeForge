---
name: release
description: >
  Create a new release candidate for the KeeForge iOS app. Bumps the version in project.yml,
  updates CHANGELOG.md, runs the full unit and UI test targets, commits, tags, and pushes
  to trigger Xcode Cloud.
  Use this skill whenever the user wants to cut a release, create a release candidate,
  bump the version, ship a new version, or prepare a build for TestFlight/App Store.
  Triggers on phrases like "release", "new version", "bump version", "cut a release",
  "prepare release", "ship it", "release candidate", or "push a new build".
---

# Release Candidate Workflow

Create a new release candidate for the KeeForge iOS app. This is a sequential, high-stakes
workflow: each step depends on the previous one succeeding. Do not skip steps or proceed
past a failure.

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
3. Run `git tag --list 'v*'` to get all existing version tags (the fetch above pulled remote tags too — Xcode Cloud triggers on the remote tag, so a remote-only duplicate is just as fatal as a local one).
4. Verify:
   - The tag `v{version}` does not already exist.
   - The version is a valid semver (MAJOR.MINOR.PATCH).
   - The new version is greater than the current `MARKETING_VERSION`.
5. If any check fails, explain the problem and ask the user how to proceed (e.g. a corrected version). Do not proceed until validation passes.

**Resume exception:** if the working tree is dirty but the only changes are this release's own
edits (`project.yml`, `CHANGELOG.md`, and `KeeForge.xcodeproj` already showing the expected new
version), a previous run of this skill likely stopped at a test failure. Confirm with the user,
then resume from Step 4 instead of redoing Steps 2-3 or demanding a reset.

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

## Step 3: Update project.yml

Update **both** the `KeeForge` and `KeeForgeAutoFill` targets:

1. Set `MARKETING_VERSION` to the new version string (e.g. `"1.6.0"`).
2. Reset `CURRENT_PROJECT_VERSION` to `"1"`.

Both targets must always have identical version values. Use precise string-replacement edits
for these changes. There are exactly 4 values to update: 2 `MARKETING_VERSION`
values and 2 `CURRENT_PROJECT_VERSION` values.

## Step 4: Regenerate Xcode project and run tests

Since `project.yml` changed, regenerate the `.xcodeproj` before building:

```bash
xcodegen generate
```

Then run the release verification tests in a fresh `bash` session. Release validation is an
explicit full-suite exception to the usual smallest-slice testing rule: run every existing unit
test, every existing UI test, and the KDBX compatibility gate (Step 4b) before committing,
tagging, or pushing.

Use target-level `-only-testing:` selectors so the command remains explicit while covering each
entire test target. Do not substitute individual class or method slices for the required release
verification run. Reset the simulator before each test target so release validation starts from
clean app and extension state:

Write each run to a result bundle so failures can be diagnosed (xcodebuild refuses to overwrite
an existing bundle, so clear the paths first):

```bash
rm -rf build/release-tests
xcrun simctl shutdown "iPhone 17 Pro" || true
xcrun simctl erase "iPhone 17 Pro"

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests -quiet \
  -resultBundlePath build/release-tests/KeeForgeTests.xcresult

xcrun simctl shutdown "iPhone 17 Pro" || true
xcrun simctl erase "iPhone 17 Pro"

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests -quiet \
  -resultBundlePath build/release-tests/KeeForgeUITests.xcresult
```

Failure policy:

- **Unit test failures are hard stops.** Report them and do not proceed to commit. Help the
  user fix them if asked.
- **UI test failures get exactly one targeted retry.** UI tests can flake on a freshly erased
  simulator. Re-run only the failed tests (`-only-testing:KeeForgeUITests/<Class>/<test>`)
  once. If they pass in isolation, the release may proceed, but report to the user which tests
  needed a retry. If any test fails again, treat it as a real failure: stop and report. Never
  retry more than once, and never re-run the whole suite to "get a green run".

## Step 4b: Run the KDBX compatibility gate

This is a required local release gate — Xcode Cloud does not install KeePassXC, so the release
machine is the only place KeeForge-produced databases get cross-validated against another
KeePass implementation:

```bash
ci_scripts/run_kdbx_compatibility_gate.sh
```

If `keepassxc-cli` is not installed, stop and ask the user to install KeePassXC (or point
`KEEPASSXC_CLI` at the binary). Do not skip this gate or proceed past a gate failure.

## Step 5: Commit, tag, and push

Only reach this step if all tests and the compatibility gate pass.

1. Stage the changed files (the `.xcodeproj` is tracked and changes when `xcodegen generate` runs):
   ```bash
   git add project.yml CHANGELOG.md KeeForge.xcodeproj
   ```
2. Commit with message: `Release v{version}`
3. Create an annotated tag:
   ```bash
   git tag -a v{version} -m "Release v{version}"
   ```
4. Push the commit and tag:
   ```bash
   git push origin main --follow-tags
   ```

After pushing, confirm success and remind the user that Xcode Cloud will pick up the
`v{version}` tag and start the build, test, TestFlight, and App Store Review pipeline.
