# Merge the release branch back into main

Do this as soon as the fix lands, not at ship time — a fix that exists only on the release branch
regresses the moment `main` becomes the next release.

Merge the whole branch; do not cherry-pick individual commits. A merge makes "is every release fix
on main?" an exact question git can answer, which cherry-picking cannot.

```bash
git fetch origin
git switch main
git pull --ff-only
git merge --no-ff --signoff origin/release/{major}.{minor} \
  -m "Merge release/{major}.{minor} into main (v{version} repo build {repoBuild})"
git push origin main
git switch release/{major}.{minor}
```

`CHANGELOG.md` is the likeliest conflict, though [release branch cut](new-release.md#commit-the-release-content-to-main-then-cut-the-branch) removes most of it by putting the
`## v{version}` section on `main` before the cut. It can still happen when a respin adds a bullet
to the version section while `main` has accumulated new `## Unreleased` entries. Resolve by keeping
both — `## Unreleased` with main's newer entries on top, the version section below it.

The merge carries the release mechanics (version bump, repo build, and What's New content) to
`main`; that is intended, so [production shipping](../../ship-release/SKILL.md) has no separate sync step.
