---
name: release
description: >
  Create a new release candidate for the KeeForge iOS app. Bumps the version in project.yml,
  updates CHANGELOG.md, runs the local KDBX compatibility gate, commits, and pushes an
  rc/<version> tag so Xcode Cloud runs the full test suite; once that cloud run passes, pushes
  the v<version> tag to trigger the Xcode Cloud build-and-archive workflow.
  Use this skill whenever the user wants to cut a release, create a release candidate,
  bump the version, ship a new version, or prepare a build for TestFlight/App Store.
  Triggers on phrases like "release", "new version", "bump version", "cut a release",
  "prepare release", "ship it", "release candidate", or "push a new build".
---

# Release Candidate Workflow

Create a new release candidate for the KeeForge iOS app. This is a sequential, high-stakes
workflow: each step depends on the previous one succeeding. Do not skip steps or proceed
past a failure.

Test execution model: the full unit and UI suites run on **Xcode Cloud**, not locally. The
release is gated in two tag stages:

1. `rc/{version}` tag → Xcode Cloud **"Tests (RC)"** workflow (test-only, all suites).
2. `v{version}` tag (pushed only after the RC run is green) → Xcode Cloud **"Release"**
   workflow (test + archive).

The only test that still runs locally is the KDBX compatibility gate, because Xcode Cloud
does not install KeePassXC.

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
is already pushed and an `rc/{version}` tag exists, resume from Step 7 (check the cloud run)
rather than recreating the commit.

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

1. Use only the new version's `### New Features` bullets in `CHANGELOG.md` as source material.
   Exclude fixes, security hardening, known issues, and internal changes. If there are no New
   Features, confirm that `WhatsNewCatalog` has no case for this version and continue without an
   empty sheet.
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
been deliberately omitted because the release contains no new features.

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

Do **not** run the full unit or UI test suites locally — they run on Xcode Cloud in Step 7.

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
2. Commit with message: `Release v{version}`
3. Push the commit:
   ```bash
   git push origin main
   ```
4. Create and push the RC tag (this triggers the Xcode Cloud **"Tests (RC)"** workflow —
   test-only, no archive):
   ```bash
   git tag -a rc/{version} -m "RC for v{version}"
   git push origin rc/{version}
   ```
   If `rc/{version}` already exists from an earlier attempt, use the next attempt suffix
   instead: `rc/{version}-2`, then `rc/{version}-3`, and so on. Never delete or force-move an
   existing tag — a re-pushed same-name tag does not reliably retrigger Xcode Cloud.

## Step 7: Wait for the Xcode Cloud RC test run to pass

The RC tag push starts the **"Tests (RC)"** workflow: the full `KeeForgeTests` and
`KeeForgeUITests` suites on parallel iPhone simulators. A run takes roughly 40-60 minutes.

1. Where to check: App Store Connect → KeeForge → Xcode Cloud → Builds, under the
   `rc/{version}` group (workflow "Tests (RC)"). If browser access is available, monitor it
   directly; otherwise ask the user to confirm the outcome (Xcode Cloud also emails them on
   completion).
2. The gate is the **Test - iOS action passing on every destination** (green check, 0 test
   failures).
3. Failure policy — hard stop:
   - Do not push the `v{version}` tag.
   - Diagnose from the build's Tests/Issues tabs. Fix on `main` as a new commit (never amend
     or force-push the release commit).
   - Push a **new** RC tag on the fix commit (`rc/{version}-2`, `-3`, ...) and repeat this step.
   - Only proceed when a Tests (RC) run is green on the exact commit that will be released.

## Step 8: Push the release tag

Only after the RC run is green.

1. Confirm `main` still points at the RC-tested commit (`git rev-parse main` equals the commit
   the green RC tag points to, `git rev-list -n1 rc/{version}`). If commits landed in between,
   either move them out or go back to Step 6 and cut a new RC — never release a commit the RC
   run did not test.
2. Tag the exact tested commit and push (this triggers the Xcode Cloud **"Release"** workflow —
   test + archive):
   ```bash
   git tag -a v{version} -m "Release v{version}" $(git rev-list -n1 rc/{version})
   git push origin v{version}
   ```

After pushing, confirm success and remind the user that Xcode Cloud will pick up the
`v{version}` tag and start the build, test, TestFlight, and App Store Review pipeline.
