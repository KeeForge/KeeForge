# Prepare a new minor or major release

## Validate repo state and version

1. Verify the git state is releasable:
   - On `main` (`git branch --show-current`).
   - Clean working tree (`git status --porcelain` is empty).
   - Up to date: `git fetch origin --tags`, then confirm `main` is not behind `origin/main`.
2. Read `project.yml` and extract the current `MARKETING_VERSION` from the `KeeForge` target.
3. Run `git tag --list 'v*'`, `git tag --list 'rc/*'`, and `git branch -r --list 'origin/release/*'`.
4. Verify:
   - `v{version}` does not already exist.
   - `{version}` is valid semver (MAJOR.MINOR.PATCH) and greater than the current `MARKETING_VERSION`.
   - `release/{major}.{minor}` does not already exist. **If it does, this is [candidate respin](../../respin-release/SKILL.md) or D, not [release preparation](../SKILL.md).**
5. If a version was not supplied, suggest the next minor bump and ask the user to confirm.
6. Once the version is confirmed, verify that the signed-in App Store Connect Xcode Cloud product
   settings are reachable. Read the actual Next Build Number at [build-number selection](candidate.md#set-the-candidate-build-number) immediately before changing the
   project.

## Update CHANGELOG.md

1. Read `CHANGELOG.md`.
2. Find `## Unreleased` and collect all entries beneath it (up to the next `## v` heading).
   Entries may be flat bullets, already grouped under `###` subsections, or a mix.
3. If the Unreleased section is empty, warn the user and ask whether to proceed.
4. Organize the entries into categorized subsections. Keep entries already under a matching
   subsection where they are; classify each remaining bullet:
   - **New Features** — new user-facing capabilities
   - **Fixes** — bug fixes
   - **Security** — security-related changes
   - **Known Issues** — known problems or limitations
   - **Changes** — refactors, renames, internal improvements, infrastructure, test changes

   Only include subsections that have entries. Keep the original wording of each bullet.
5. Replace the Unreleased entries with the new versioned section:

```markdown
## Unreleased

## v{version} ({YYYY-MM-DD})

### New Features
- ...

### Fixes
- ...
```

The `## Unreleased` heading stays; its content moves into the new version section. Use today's
date in the user's timezone — do not guess. If the soak runs past that date, correct it in [production shipping](../../ship-release/SKILL.md).

## Review and fix What's New content

Perform this review for every release, even if the content already looks complete.

1. Review the new version's `### New Features` and `### Fixes` bullets as source material. Keep
   the sheet to at most three items by default, honoring an owner-requested larger count. Prioritize
   the most important user-facing features, then use remaining slots for notable bug fixes. A fix is notable when it materially improves a common
   workflow, prevents a crash or data-loss risk, or delivers a broad reliability improvement.
   Exclude routine polish, security hardening, known issues, and internal changes. If there are no
   eligible items, confirm `WhatsNewCatalog` has no case for this version and continue without an
   empty sheet. A feature proposal is preliminary; the exact-copy and rendered-sheet approvals
   below are required before committing.
2. Inspect the matching version case in
   `KeeForge/Services/AppSupport/WhatsNewPresentationService.swift`. Add it if needed, or fix it
   when stale, incomplete, overly technical, or inaccurate.
3. Rewrite each included feature as short, benefit-led copy for ordinary users. Do not copy issue
   numbers, implementation details, test coverage, internal terminology, or raw changelog prose.
4. Check platform accuracy. Keep features available on both iOS and macOS shared; set the
   `platforms` argument for single-platform features. Never advertise an iOS-only feature in the
   Mac sheet or vice versa.
5. Add or update every affected key and its translations for every shipped locale (see AGENTS.md's
   Localization section; `KeeForgeTests/LocalizationTests.swift` is the source of truth) in
   `KeeForge/Resources/Localizable.xcstrings`. The localization tests in the RC run are the gate.
6. Re-read the completed sheet as a user. Fix unclear titles, repetitive descriptions, missing
   major features, or claims the release does not support.
7. Complete both [release-content preview](shared.md#release-content-preview-before-commit)
   approvals: show the exact final headings and paragraphs, then the actual rendered screenshots.
   Finish the local preview and obtain screenshot confirmation before the commit/branch-cut step.

## Commit the release content to main, then cut the branch

Everything decided **once** for this release lands on `main` before the cut; only what varies
**per candidate** waits for the branch. [release changelog](new-release.md#update-changelogmd), [What's New review](new-release.md#review-and-fix-whats-new-content), and the marketing version are all in the first
group — they describe work already merged to `main`, and the changelog heading already commits to
the version number, so holding the matching `MARKETING_VERSION` back buys nothing.

Set `MARKETING_VERSION` to the new version string (e.g. `"1.11.0"`) on **all four** product
targets in `project.yml` — `KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, and `KeeForgeMacAutoFill`.
The Mac targets ship in lockstep with iOS (same marketing version and repo build). Leave
`CURRENT_PROJECT_VERSION` alone here; [build-number selection](candidate.md#set-the-candidate-build-number) advances it globally for the first candidate.

Generate the project and capture the preview before committing. Continue only after both
[release-content preview](shared.md#release-content-preview-before-commit) approvals cover the
exact files being committed.

```bash
xcodegen generate
git add CHANGELOG.md project.yml KeeForge.xcodeproj \
  KeeForge/Services/AppSupport/WhatsNewPresentationService.swift \
  KeeForge/Resources/Localizable.xcstrings
git commit -s -m "Prepare v{version}"
git push origin main
```

`main` now builds as `{version}`, so local dev builds will show the new What's New sheet once —
`WhatsNewCatalog` is keyed by version string and the marketing version now matches it. That is
harmless and self-limiting: `WhatsNewPresentationHistory` presents each version at most once per
device.

Then cut the branch from that commit. It is named for the **minor** version, not the patch —
`release/1.11` carries `1.11.0`, `1.11.1`, and every later patch. It is long-lived: do not delete
it until the next minor ships.

```bash
git switch -c release/{major}.{minor}
git push -u origin release/{major}.{minor}
```

The `release branches` repository ruleset covers `refs/heads/release/**` — deletion protection,
linear history, and required `unit-tests` + `DCO` checks — so contributor PRs into this branch
are gated exactly like `main`.

From here until [production shipping](../../ship-release/SKILL.md), **all release work happens on this branch.** `main` stays open for the
next version's features. If the release is abandoned or renumbered after this point, reverting this
one commit on `main` undoes all of it together.
