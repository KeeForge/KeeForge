---
name: pre-release-review
description: >
  Review KeeForge changes since a shipped release for ecosystem documentation and
  translation inconsistencies, test quality and coverage gaps, and platform-specific
  manual testing needs. Run useful verification and save an organized pre-release
  report. Use for a pre-release review or readiness audit before starting a candidate;
  this is a separate step from cutting, respinning, or shipping a release.
---

# KeeForge Pre-release Review

Review changed behavior and its surrounding contracts before the release process starts.
Produce evidence-backed findings and a focused manual test plan. Invocation authorizes
necessary verification, including tests, and writing review artifacts. Source fixes,
website edits, issue mutations, commits, and release operations are separate work unless
the user also requests them. Do not invoke release preparation, respinning, or shipping skills automatically.

## Establish the scope

Read the repository and local guidance, then [report-format.md](references/report-format.md).
Once the baseline and target are resolved, create an in-progress report at the canonical
shared location before the detailed review.

- Resolve the target to a full commit SHA; default to `HEAD`. Record the working tree's
  dirty state separately. Never attribute uncommitted code or test results to that SHA.
- Fetch release refs when available without rewriting tags. Select the most recent
  applicable shipped `vMAJOR.MINOR.PATCH` tag reachable from the target, using release
  lineage and release evidence rather than tag timestamp alone. Exclude `rc/*` tags.
  Record both the tag and its dereferenced SHA. An explicit baseline takes precedence.
  If the baseline is ambiguous, missing, or not an ancestor, resolve that with the user;
  continue independent inventory work without inventing a release boundary. Disclose
  when remote release evidence could not be checked.
- Inspect `base..target` history and the net diff between those commits. Group changes
  by behavior, accounting for reversions, merges, and fixes that supersede earlier work.
  Follow affected callers and contracts even when their files did not change.
- Include iPhone, iPad, Mac App Store, direct-download Mac, and both AutoFill extensions
  where relevant. Read affected folder docs, the resource catalog guidance, the test
  maps, and the macOS README's testing table on demand.
- Discover the separate website checkout (on Tan's Mac, `/Users/tan/src/keeforge.com`),
  read its local guidance, and record its SHA and dirty state independently. Inspect
  relevant pages on `https://keeforge.com` as well as source. Source is not proof of
  deployment; record URLs and inspection time. Missing access is a coverage limitation.

Review committed snapshots. If the checkout differs from the target, use Git reads for
static review and identify the actual source state of any tests. Do not discard user
changes or switch their checkout to manufacture a clean result. If testing the exact
target needs another checkout, follow the environment's worktree guidance.

## Parallel review

Use sub-agents where independent work can make the review faster or more thorough.
After establishing one baseline and target, fan out bounded areas such as ecosystem
documentation/translations, test coverage, or platform-specific risks and manual checks.
Keep small or tightly coupled reviews in one agent rather than forcing delegation.

Give each sub-agent the exact app and website revisions, assigned scope, relevant local
guidance, and the audit-only boundary. Ask for actionable findings with evidence and
material limitations, not a narrative of everything inspected. Assign separate evidence
files if needed; only the coordinating agent edits `report.md`.

Coordinate test execution centrally to avoid duplicate runs and shared-resource races.
Sub-agents may run independent checks, but Xcode, simulator, device, and UI operations
must follow the repository's locking and destination rules. Parallel review does not
authorize concurrent project regeneration or competing control of the same UI/device.

The coordinating agent checks delegated findings, resolves contradictions, deduplicates
overlap, and reviews contracts spanning assigned areas. Wait for delegated work or record
unfinished coverage explicitly before finalizing. Produce one concise report using the
same inclusion rules as a single-agent review; do not concatenate sub-agent reports.

## Review lanes

### Ecosystem consistency

Trace changed capabilities through app and AutoFill labels, help, errors, settings,
onboarding, changelog, relevant What's New content, maintained READMEs, agent docs,
translated root README/CONTRIBUTING files, and website content and screenshots.
Check behavior, platform availability, requirements, and instructions agree.

For changed strings, inspect meaning, terminology, placeholders, plural handling, and
likely truncation across every shipped locale, discovering the current locale set from
the catalogs and localization tests. Include app and extension catalogs. Mechanical
completeness does not prove translation quality; identify uncertainty requiring a human
language review. Check catalog normalization without rewriting it during an audit.

The live website normally describes the shipped release. A new feature awaiting launch
is a coordinated launch task, not automatically a current website defect. Separate
incorrect existing claims from upcoming updates. Do not require future version numbers
or a finished What's New sheet before release preparation. Historical `docs/specs` are
context, not maintained contracts; do not propose synchronizing them by default.

### Coverage and test quality

Use [test-audit](../test-audit/SKILL.md)'s authoring and retention criteria when judging
test quality. Keep this review scoped to changed behavior; an exhaustive subsystem
campaign is separate work, and findings belong in this review's existing report.

Map changed behavior to actual test assertions and execution destinations. Assess:

- Success, failure, cancellation, persistence/reopen, and regression paths where relevant.
- Assertions that prove the outcome rather than mirror the implementation; mocks and
  test flags that bypass the behavior supposedly covered.
- Target membership, compile guards, CI selection, and skip conditions. A test that
  never executes on configured destinations is not effective coverage.
- Redundancy at the same layer: identify the tests, their equivalent guarantees, and
  any unique protection before recommending consolidation. Shared iOS/Mac execution,
  independent compatibility oracles, and complementary unit/UI checks are not redundant
  merely because they exercise similar flows.
- UI-only gaps in navigation, focus, keyboard interaction, accessibility, system panels,
  and compact/regular layouts. Prefer a unit-test seam when it proves the behavior;
  use the smallest UI case for an interaction that requires UI. Visual polish usually
  needs screenshot inspection rather than new assertions.

Recommend concrete tests or consolidation with the smallest useful scope. Do not use
test counts or an arbitrary coverage percentage as the readiness criterion.

### Compatibility test additions

Explicitly assess whether changes since the baseline require new or expanded compatibility
tests. Include database creation, edit operations, parsing/writing, protected fields,
unknown XML, and AutoFill, cloud, or local saves, even when the parser/writer itself did
not change. Passing existing tests does not prove a new behavior has compatibility coverage.

Read the compatibility guidance in `KeeForgeTests/AGENTS.md` and `ci_scripts/README.md`.
Map affected behavior to `KeeForgeTests/KDBXCompatibilityTests.swift`, fixtures, and
`KeeForgeTests/KDBXCompatibilitySupport.swift`. Check both foreign-authored input and
KeeForge-written output where relevant, including preservation after edit/save/reopen.
Distinguish in-process assertions from what an independent reader actually verifies.

For each meaningful gap, recommend the exact fixture/scenario and assertions needed,
including platform/save-path coverage. Check whether artifact descriptors, emission,
external expectations, and `ci_scripts/run_kdbx_compatibility_gate.sh` need corresponding
updates, especially when the supported compatibility matrix changes. Follow the existing
one-run-per-scenario design rather than duplicating expensive tests. Surface actionable
gaps in the concise report; omit a routine all-clear. Recommend additions during the
audit; implement them only when fixes are also requested.

### Change-driven risk checks

Review these when affected by the change or its dependencies, not as an exhaustive
repository audit:

- Data integrity: saves and reopen, conflict/merge recovery, backups, protected fields,
  unknown XML preservation, and independent KeePass interoperability. Check whether
  compatibility scenarios and artifact expectations cover the new behavior.
- Security/privacy: lock and authentication boundaries, secret handling and logging,
  network egress, permissions, entitlements, and privacy declarations. Recommend a
  dedicated security review when warranted; this review is not a security certification.
- Integration: extension-safe APIs, target membership, identical AutoFill allow-lists,
  minimum-OS availability, and Mac App Store/direct-build differences.
- Existing installs and recovery: upgrade behavior, interrupted/offline operations,
  large vaults, and performance or resource limits when the changes make them relevant.

### Manual testing plan

Derive a prioritized checklist from the actual changes and automated blind spots.
Each item needs a reason, affected platforms/channels and OS/device requirements,
fixture/setup, concrete steps, expected results, approximate effort, and result status.
Use disposable fixture copies and test accounts for destructive or external-write flows.
Do not exercise real user vaults as test data.

Include real system AutoFill panels, provider-backed sync, biometrics, hardware keys,
camera/deep links, upgrade paths, accessibility, and visual/language checks only where
relevant. Separate checks possible now from those needing the eventual RC artifacts.
A manual item starts as `not-run`; creating the plan does not mean executing it.

## Verify findings

Run whatever tests materially help establish a finding or close an uncertainty. Start
with focused slices, widening to compatibility gates, UI tests, or broader suites when
justified. The user's review request permits necessary test execution; do not stop at
suggesting commands when you can run useful verification. Follow repository guidance
for test selection, the physical-device preference, global Xcode lock, and full logs.
Do not run full suites reflexively or repeat passed checks without new evidence.

Inspect CI evidence when useful, tying it to its actual commit, target, and destination.
Record local commands, source state, destination, executed/skipped counts when available,
results and logs/result bundles in supporting evidence, not the human-facing report.
Zero executed tests is not a pass. Distinguish assertion
failures, infrastructure failures, skipped runs, and verification that was not attempted.
Respect fixture limitations: a mocked provider test does not prove real provider sync.

Run read-only checks such as catalog normalization `--check` as appropriate. Tests may
produce build artifacts; inspect Git status afterward and preserve any unexpected source
changes separately rather than silently including them in the reviewed revision.
Never bypass authentication or change security settings to make verification run.
If a check cannot run, finish the useful review and record the limitation precisely.

## Finish and hand off

Keep `report.md` short and decision-focused. Include only actionable findings, noticeable
user impact, material verification limitations, and prioritized manual checks. Do not
include an audit trail, file/commit inventories, clean-area summaries, routine passing
tests, exhaustive coverage matrices, generic advice, or empty sections. Review broadly;
report selectively. Do not manufacture findings to fill a template or bury important
findings merely to meet a length target.

Every finding needs concise evidence, impact, affected platforms, confidence where
uncertain, and a concrete recommendation. Group findings as
`fix-before-rc`, `coordinate-for-launch`, or `follow-up`; distinguish a confirmed defect
from a suspected gap or unverified behavior. Deduplicate by root cause without hiding
distinct platform consequences. Keep detailed verification and coverage notes in
`evidence/` only as needed for traceability; link directly to evidence that supports a
finding. Do not reproduce those notes in the report or final chat response.

Review completion and finding resolution are separate. A complete review can have open
findings and pending manual tests. Mark it incomplete when review lanes or necessary
verification remain unchecked; do not claim readiness from absence of evidence.
Link the report in a brief final response with only the most important actions or risks.
If there are no material findings, say so in one sentence, adding only necessary manual
checks or limitations. Do not recap everything inspected.

For a follow-up, keep `report.md` as the concise current decision summary. Preserve prior
findings and append the new commit range, evidence, and finding status changes in
`evidence/follow-ups.md`; remove resolved items from the current report unless their
resolution materially affects the release decision. Update affected manual checks and
the effective reviewed
commit only after reviewing that delta and its affected contracts. A different baseline
or unrelated release line gets a new report. A review is not a waiver of the release
skill's mandatory gates on the exact candidate artifacts.
