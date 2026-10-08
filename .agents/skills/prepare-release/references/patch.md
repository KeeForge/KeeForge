# Prepare a patch version

For `1.11.1` on top of a shipped `1.11.0`.

## Branch is already there

Patches are cut from the existing `release/{major}.{minor}` branch — **never from `main`**, which
by now carries the next version's features.

```bash
git switch release/{major}.{minor}
git pull --ff-only
```

Verify the branch contains the latest shipped tag for this minor version. Confirm the new patch
version is greater than that shipped version and that its `v{version}` tag does not exist.
If that version already has an RC, continue with `respin-release` instead.

## Land the fix and bump

1. Land and push the fix as a new commit on the release branch and merge it back promptly using [merge-back guidance](merge-back.md#merge-the-release-branch-back-into-main).
2. Confirm the patch marketing version, then run the App Store Connect build-number preflight and
   [build-number selection](candidate.md#set-the-candidate-build-number)'s repository-floor command and apply [build-number selection](candidate.md#set-the-candidate-build-number)'s comparison and edit rules. In `project.yml`, set
   `MARKETING_VERSION` to the patch version and set the global
   `CURRENT_PROJECT_VERSION` on all four targets to exactly `xcodeCloudNextBuild`. Never reset it
   to `"1"`.
3. Add a `## v{version} ({date})` section to `CHANGELOG.md` above the previous version's section.
4. Run [What's New review](new-release.md#review-and-fix-whats-new-content) only if the patch has a user-visible highlight worth a What's New sheet. Most patches do
   not; confirm `WhatsNewCatalog` has no case rather than shipping an empty sheet.
5. Complete [release-content preview](shared.md#release-content-preview-before-commit) before
   committing the patch release content. Preview its exact headings and paragraphs even when no
   What's New sheet is included; when it has a sheet, obtain rendered-screenshot confirmation too.

## Gate, tag, distribute

Run [local KDBX gates](candidate.md#regenerate-and-run-the-local-kdbx-gate), [RC tag and manifest](candidate.md#commit-push-and-tag-the-candidate), [candidate gates](candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke), and [artifact verification and beta distribution](candidate.md#verify-all-three-artifacts-assign-the-app-store-builds-and-distribute-when-approved) exactly as for a minor release. The KDBX gate is not optional for patches.

Merge the candidate bookkeeping back using [merge-back guidance](merge-back.md).

## Shortened soak

Patch releases target **24h** instead of 48h. Every other [soak guidance](soak.md#candidate-soak) signal is measured and reported the
same way.

When the patch fixes an active crash or data-loss bug already reaching users, recommend shipping
  as soon as all [candidate gates](candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke) gates are accepted — for that class of bug, more soak time is usually worse for
users than less. Say that explicitly rather than leaving the user to infer it.

The gates themselves are still invariant 3: green, or every failure adjudicated. A patch under
time pressure is exactly when it is tempting to skip them, and exactly when a second bad build
does the most damage.

## Ship

Hand off to `ship-release` only when the user requests production shipping, reporting against
the 24h target in place of 48h. Beta distribution is a valid stopping endpoint.
