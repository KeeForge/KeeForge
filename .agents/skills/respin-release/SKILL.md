---
name: respin-release
description: Replace an unshipped KeeForge candidate after a fix on an existing release branch. Keep the marketing version, advance the global build number, rebuild all three channels, repeat gates, and restart soak. Use for a respin or another RC of the same version; use prepare-release for a new marketing version and ship-release for production publication.
---

# Respin a KeeForge candidate

Read [the shared release contract](../prepare-release/references/shared.md) first.
Confirm the release branch and candidate manifest, and verify that `v{version}` does not exist.
A fix to a shipped version needs [prepare-release](../prepare-release/SKILL.md).

Use when a fix must land on a live release branch. Every respin produces a new build and restarts
the soak clock.

## Land the fix on the release branch

The fix goes on the release branch **first** — that is where it is needed. Contributor fixes come
in as PRs targeting `release/{major}.{minor}` and are gated by `pr-tests.yml` and the ruleset.

Never amend or force-push an existing release commit; the fix is always a new commit.
Push the fix and merge it back promptly using
[merge-back guidance](../prepare-release/references/merge-back.md), then return to the release branch.

## Bump the build number

Run the App Store Connect build-number preflight again for this respin; never reuse the observation
from the prior candidate. Then run [build-number selection](../prepare-release/references/candidate.md#set-the-candidate-build-number)'s repository-floor command and apply [build-number selection](../prepare-release/references/candidate.md#set-the-candidate-build-number)'s comparison and edit
rules. Set `repoBuild` to exactly the verified `xcodeCloudNextBuild` on
**all four** targets: `KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, and `KeeForgeMacAutoFill`.
Never reset it; `MARKETING_VERSION` does not change. Carry both preflight values and `repoBuild`
into the manifest after [RC tag and manifest](../prepare-release/references/candidate.md#commit-push-and-tag-the-candidate) initializes it, then rebuild iOS, MAS, and direct artifacts from the new
RC commit.

If the fix warrants a user-visible changelog line, add it to the version's section in
`CHANGELOG.md` (not `## Unreleased` — this version is no longer unreleased on this branch).

## Regenerate, gate, tag

Run [local KDBX gates](../prepare-release/references/candidate.md#regenerate-and-run-the-local-kdbx-gate) (regenerate + KDBX gate), then [RC tag and manifest](../prepare-release/references/candidate.md#commit-push-and-tag-the-candidate) with the new build number, then [candidate gates](../prepare-release/references/candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke) and [artifact verification and beta distribution](../prepare-release/references/candidate.md#verify-all-three-artifacts-assign-the-app-store-builds-and-distribute-when-approved).

Both KDBX gates run again for this build. They are not inherited from the previous candidate.

## Restart the soak

Return to [soak guidance](../prepare-release/references/soak.md#candidate-soak) with the clock reset to this build's distribution timestamp. Prior builds' soak time
does not carry over.

Merge the candidate bookkeeping back using [merge-back guidance](../prepare-release/references/merge-back.md)
without waiting for soak or shipping.
