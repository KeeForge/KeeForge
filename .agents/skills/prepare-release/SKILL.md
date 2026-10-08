---
name: prepare-release
description: Prepare the first KeeForge candidate for a new marketing version, including minor/major releases and patches or hotfixes to shipped versions. Prepare version and release notes, use the correct release branch, build and gate iOS, Mac App Store, and direct Mac artifacts, and hand off for soak. Use for a new version, version bump, release cut, patch, or initial TestFlight candidate; use respin-release for another candidate of the same version and ship-release for production publication.
---

# Prepare a KeeForge release

Read [the shared release contract](references/shared.md) first. Establish the requested version,
release branch, and existing shipped/RC tags before changing files.

- **New minor or major:** read [new-release.md](references/new-release.md). Prepare release content
  on `main`, then cut `release/{major}.{minor}`.
- **Patch to a shipped version:** read [patch.md](references/patch.md). Use the existing
  `release/{major}.{minor}` branch so the patch excludes newer features on `main`.
- **Another candidate of an unshipped version:** use [respin-release](../respin-release/SKILL.md).
- **Publish an accepted candidate:** use [ship-release](../ship-release/SKILL.md).

If the requested version or starting point is ambiguous, resolve it before mutation.

Before committing release content, obtain approval of the exact headings and paragraphs, then
confirmation of the rendered What's New screenshots. Follow the shared
[release-content preview](references/shared.md#release-content-preview-before-commit) requirement;
an approved feature outline alone is insufficient.

Both preparation paths use the same [candidate procedure](references/candidate.md): build-number
preflight, both local KDBX gates, immutable RC tag/manifest, hosted gates and local Mac smoke,
exact artifact verification, and authorized beta distribution. Follow those steps in order;
patches do not skip gates. Read [soak.md](references/soak.md) for the handoff and measurements:
48 hours for a minor/major release, 24 hours for a patch. A respin resets that version's clock.

Merge release-branch changes back using [merge-back.md](references/merge-back.md).
Stop at the beta/direct-artifact handoff unless production shipping is explicitly requested.
