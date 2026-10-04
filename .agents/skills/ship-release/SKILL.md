---
name: ship-release
description: Ship an accepted, soaked KeeForge candidate across iOS, Mac App Store, and direct Mac. Verify the recorded artifact identities and soak evidence, coordinate App Store review, create the shipped tag after approval and final go, publish the exact artifacts, and reconcile released issues. Use when asked to ship or promote a soaked build; never create a replacement candidate here.
---

# Ship a KeeForge release

Read [the shared release contract](../prepare-release/references/shared.md) and
[soak guidance](../prepare-release/references/soak.md), then follow this workflow.

Use this skill when the user decides to ship, after the [soak guidance](../prepare-release/references/soak.md#candidate-soak) signals have been reported to them.

**Do not re-check the CI gates here.** All cloud gates and local gates were read and adjudicated in [candidate gates](../prepare-release/references/candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke), and accepting
them is what allowed the build to reach external testers in the first place (invariant 3). That
verdict is [release preparation](../prepare-release/SKILL.md)'s job and it is final: do not poll Xcode Cloud or GitHub Actions check runs for
the RC commit, do not reopen [gate-adjudication.md](../prepare-release/references/gate-adjudication.md), and do not treat a test action that was red but
accepted as a flake — or a later re-run of either workflow — as a reason to stop. The soaked binary
already carries the verdict. If it turns out a gate was never accepted, you are not in [production shipping](SKILL.md); go
back to [candidate gates](../prepare-release/references/candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke).

## Confirm what you are shipping

Record explicitly, and state it back to the user before proceeding:

- The marketing version, repo build, and both **TestFlight** build numbers of the soaked builds.
- Its `rc/{version}-b{repoBuild}` tag and commit SHA. The tag identifies the commit; each
  platform-specific TestFlight number identifies its binary, and neither is required to equal the
  repo build.
- The direct Mac `CFBundleVersion`, zip hash, and notarization ID.
- Both distribution timestamps, elapsed soak times, unique-install/crash counts, and direct install/update results.
- Which [soak guidance](../prepare-release/references/soak.md#candidate-soak) signals, if any, are short of target.

Each TestFlight build number here **is** the build you will select for its platform in App Store
Connect. If either does not match the build distributed and soaked, stop — something is out of
sync. Do not substitute a newer build.

## Correct the changelog date if the soak crossed a day

If `CHANGELOG.md`'s `## v{version} ({date})` no longer matches the actual ship date, fix it on the
release branch now. This is a documentation-only change and does **not** require a new build — the
changelog is not compiled into the binary. Merge that correction to `main` before the audit below.

## Audit that main has every fix

Because backports and the date correction are merges, this is an exact check rather than a judgement call:

```bash
git fetch origin --tags
git merge-base --is-ancestor origin/release/{major}.{minor} origin/main \
  && echo "main contains the release branch" \
  || git log --oneline origin/main..origin/release/{major}.{minor}
```

If the check fails, the listed commits are on the release branch and not on `main`. Run [merge-back guidance](../prepare-release/references/merge-back.md#merge-the-release-branch-back-into-main) to
merge them before shipping. Do not ship with an unmerged fix.

## Stage both App Store submissions; do not create the shipped tag yet

Invoke `publish-app-store-version` once for iOS and once for macOS. Attach the exact soaked
TestFlight build numbers from the manifest, save the platform-specific metadata/screenshots, and
stage each platform independently through **Ready for Review**, then stop. Do not submit either
platform yet. If the user later requests submission, obtain separate explicit action-time
confirmation immediately before each platform's API submission request; confirmation for one
platform does not authorize the other. Configure both records for manual release and leave approved
versions held. `v{version}` does not exist yet.

If Apple requests a metadata-only correction, fix only that platform's record. If Apple requests a
code change, return to [candidate respin](../respin-release/SKILL.md) and respin all three artifacts. Never substitute a newer unsoaked
build.

## Create the shipped tag after review approval and final go

Wait until both App Store submissions have code approval and the user gives the final coordinated
go decision. Record that non-secret decision/evidence and completed soak observations in the
manifest: set each platform's `appStoreReviewState`, preserve the separate beta `reviewState`, and
record each soak's accepted verdict/evidence, metrics, or owner-accepted exceptions. Then validate
the ship evidence. Then create `v{version}` on the accepted RC commit; it triggers no build and records
the code that actually shipped. Include any accepted soak exception in the tag message.

```bash
ci_scripts/candidate_manifest.py validate \
  --manifest scratch/release-manifests/{version}-b{repoBuild}.json --mode ship
```

```bash
git fetch origin --tags
rc_tag='rc/{version}-b{repoBuild}'
rc_commit=$(git rev-list -n1 "$rc_tag")
git tag -a 'v{version}' -m 'Release v{version} — shipped RC '"$rc_tag" "$rc_commit"
git push origin 'refs/tags/v{version}'
```

Keep every `rc/*` tag. They are the audit trail of the candidates, including the ones that were
replaced.

If `git fetch origin --tags` reports `! [rejected] ... (would clobber existing tag)`, a local tag
has drifted from the remote. The remote is authoritative for released tags: inspect both sides,
then realign with `git fetch origin --tags --force`.

## Confirm main reflects the shipped state

[release branch cut](../prepare-release/references/new-release.md#commit-the-release-content-to-main-then-cut-the-branch) put the changelog section, the What's New content, and `MARKETING_VERSION` on `main` before the
cut, and the [merge-back guidance](../prepare-release/references/merge-back.md#merge-the-release-branch-back-into-main) merges carried each candidate's repo build across. Verify rather than redo:

- `main`'s `MARKETING_VERSION` is `{version}` on all four targets: `KeeForge`, `KeeForgeAutoFill`,
  `KeeForgeMac`, and `KeeForgeMacAutoFill`.
- `main`'s `CURRENT_PROJECT_VERSION` is the accepted `repoBuild` on all four targets, and the
  direct artifact's `CFBundleVersion` is also that `repoBuild`. Do not compare either value with
  the platform-specific TestFlight build numbers.
- `main`'s `CHANGELOG.md` has the `## v{version}` section, with an empty `## Unreleased` above it
  ready for the next cycle.

`CURRENT_PROJECT_VERSION` is **not** checked against either TestFlight number. Xcode Cloud manages
platform-specific build numbers and may override the project value. The repo value must still be
globally unique and increasing and must equal the direct build's `CFBundleVersion`; [build-number selection](../prepare-release/references/candidate.md#set-the-candidate-build-number) and [Bump the build number](../respin-release/SKILL.md#bump-the-build-number)
guarantee that. The manifest is the authoritative mapping between the repo build, both TestFlight
numbers, and the direct artifact.

Fix any real drift with a single `-s` commit on `main`, then push.

## Release the approved channels and verify production

After `v{version}` exists and both platform records are approved, manually release iOS and native
macOS at the coordinated time. Publish the verified GitHub Release/direct zip, then publish the
production Sparkle appcast last. Verify live installs, migration, AutoFill, WebDAV, channel
boundaries, and both App Store version/build numbers; preserve the completed non-secret manifest.

Keep the release branch. It is where `{version}.1` will come from.

## Reconcile the GitHub project

After production verification succeeds, audit
[KeeForge project 1](https://github.com/orgs/KeeForge/projects/1/views/2) for issues whose Status is
**Pending Release**. Establish the shipped boundary from the dereferenced `v{version}` tag, then
identify the implementation commit or merged pull request for each pending issue. Move an issue to
**Released** only when its implementation is reachable from that tag and the promised behavior
actually shipped on its intended platform. A changelog entry is useful corroboration but is not
required for internal tasks or refactors.

Do not infer release from the issue being closed, from its milestone, or from the implementation
being present on current `main`: work merged after the shipped tag stays **Pending Release**. Present
the exact move/leave list with the tag-containment evidence and obtain confirmation immediately
before changing project fields unless the user already explicitly authorized this reconciliation.
For the write, invoke `keeforge-github-issues`, follow its live-project preflight, change only the
Status field, and read every changed project item back to verify it now says **Released**. Do not
close or otherwise edit the issues as part of this step.
