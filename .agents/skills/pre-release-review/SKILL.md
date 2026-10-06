---
name: pre-release-review
description: >
  Statically review KeeForge changes since a shipped release for behavior risks,
  documentation inconsistencies, i18n gaps, and missing test coverage. Return a
  prioritized action list before candidate preparation, without running tests or
  writing a report. Use for a pre-release review or readiness audit.
---

# KeeForge Pre-release Review

Review changes before candidate preparation and return actionable findings in chat.
This is a static review: do not run tests, builds, compatibility gates, validation
scripts, or manual UI/device checks. Do not create a manual test plan or saved report.
Source fixes, website edits, issue mutations, commits, and release operations are
separate work unless the user requests them. Do not invoke release skills automatically.

## Establish the scope

Read repository and local guidance. Resolve the target to a full commit SHA, defaulting
to `HEAD`, and identify the most recent applicable shipped `vMAJOR.MINOR.PATCH` tag
reachable from it. Use release lineage and available release evidence; exclude `rc/*`
tags. An explicit baseline takes precedence. If the baseline is missing, ambiguous,
or not an ancestor, clarify it with the user while continuing independent inventory.

Inspect `base..target` history and the net diff, accounting for reversions and superseded
fixes. Group changes by behavior and follow affected callers and contracts. Review
committed snapshots; distinguish uncommitted changes and preserve the user's checkout.
Read affected folder docs on demand. Include iPhone, iPad, Mac App Store, direct Mac,
and both AutoFill extensions where relevant.

## Review changed behavior and coverage

For each affected behavior, assess concrete risks and the assertions that cover it:

- Data integrity: edits, saves/reopen, conflict recovery, backups, protected fields,
  unknown XML preservation, and KeePass interoperability.
- Security/privacy: lock and authentication boundaries, secret handling, logging,
  network egress, permissions, entitlements, and privacy declarations.
- Integration/recovery: extension-safe APIs, target membership, AutoFill allow-lists,
  minimum OS, platform/channel differences, existing installs, interrupted operations,
  and relevant performance limits.
- Coverage: success, failure, cancellation, and persistence paths; assertions that
  prove outcomes; mocks that bypass the relevant behavior; CI selection and skips;
  UI interactions that unit tests cannot establish.

Explicitly assess compatibility coverage when creation, edits, parsing/writing, or any
save path changes, even if the parser/writer did not change. Read test and compatibility
guidance as needed. Check foreign-authored input and independent reading of KeeForge
output, including preservation after edit/save/reopen. Recommend the smallest useful
fixture, scenario, and assertions for a meaningful gap. Existing green tests do not
prove new behavior is covered; inspect source and existing CI evidence without running
verification. Test consolidation campaigns belong to `test-audit`.

## Review i18n gaps

Read `KeeForge/Resources/README.md` and discover shipped locales from the catalogs and
localization tests. Inspect changed user-facing text and affected call sites across
the app, Mac, and AutoFill extensions for:

- Hardcoded display text or strings that bypass localized lookup.
- Missing keys, missing locale translations, empty values, and stale translations
  after English copy or behavior changes.
- Placeholder/type mismatches, plural handling, terminology, and translations that
  change the meaning or describe unsupported behavior.
- Likely truncation or ambiguous labels from source and existing screenshots; mark
  visual concerns and uncertain language judgments as unverified.

Check affected locale variants, not only English or mechanical completeness. Identify
the exact key, call site, and locales needing action or human language review.

## Review related content

Trace changed capabilities through help, errors, settings, onboarding, changelog,
relevant What's New content, maintained READMEs/agent docs, and translated root
README/CONTRIBUTING files. Check claims, platform availability, requirements, and
instructions against actual behavior. Historical `docs/specs` are context.

Inspect website source and relevant live pages when changes affect public claims or
launch content. Discover its checkout and local guidance; distinguish source from
deployment. The live site normally describes the shipped release: separate existing
inaccuracies from coordinated launch updates. Do not require a future version number
or finished What's New sheet before release preparation.

## Return action items

State the baseline and reviewed target briefly, then return a prioritized list in chat.
Use `fix-before-rc`, `coordinate-for-launch`, or `follow-up` where useful. Each item
should identify the problem or gap, user impact, affected platforms/locales, a precise
source/evidence link, and the recommended action. Distinguish confirmed defects from
suspected gaps or unverified behavior; deduplicate by root cause.

Include only worthwhile actions and material review limitations. Omit audit inventories,
routine all-clears, generic regression checklists, and release-readiness claims based
only on static inspection. If there are no actionable findings, say so in one sentence.
Mention that no tests were run and disclose unchecked areas that affect confidence.
