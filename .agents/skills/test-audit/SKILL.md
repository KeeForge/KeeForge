---
name: test-audit
description: >
  Assess KeeForge test quality, redundant coverage, and test-support complexity;
  audit a selected subsystem or apply an authoring checklist while changing tests.
  Use for test audits, consolidation, and pruning requests. Release readiness across
  changes belongs to pre-release-review; ordinary test authoring needs only the
  checklist, not an audit campaign.
---

# KeeForge Test Audit

Improve regression protection and reduce maintenance without losing distinct contracts.
Test count and deleted lines are not success criteria. Adapted from
[OpenClaw's test-audit](https://github.com/openclaw/openclaw/blob/main/.agents/skills/test-audit/SKILL.md)
for KeeForge's XCTest, shared platform targets, and independent compatibility gates.

## Scope and authority

Read root and affected folder guidance, including local overrides. For an audit, pin
the reviewed commit and record dirty files separately. Establish the subsystem and
whether the request covers discovery, cleanup, or a complete campaign. Default an audit
to read-only discovery and a report under the main checkout's shared `scratch/test-audit/`;
tests may create build artifacts. Find the main checkout with `git worktree list --porcelain`.
A plan-only request excludes test execution and file writes unless requested separately.
Apply existing user authorization rather than asking again. An audit alone does not
authorize source/test fixes, issue mutations, commits, or pushing.

Use [pre-release-review](../pre-release-review/SKILL.md) for change-driven release
readiness. When working within that static review, contribute coverage gaps to its
action list without running tests or creating a separate report. For ordinary test
changes, apply the checklist below without producing a separate audit report.

## Authoring checklist

Before adding or changing a test, identify:

- The observable outcome or independent contract and a credible regression it detects.
- The production boundary that owns the behavior and why existing tests do not already
  catch that regression. Extend a case table or shared fixture when it expresses the
  same contract without obscuring distinct failure paths.
- An expectation independent of the behavior under test. A mock should supply inputs,
  record effects, or simulate an external boundary; it must not implement the outcome
  the test claims to prove.
- Any injection or support needed, and why it is the smallest reliable way to exercise
  the real owner. Constructor injection, fake transports, clocks, notification centers,
  and system-store fakes can be necessary for deterministic, headless tests. Remove
  unnecessary hooks, not testability itself.

For bug regressions, demonstrate failure on the old behavior for the intended reason
and success with the repair when feasible; record any unverified control explicitly.
Use a disposable checkout or reversible isolated patch for controls, preserving user
changes. A failing build or an unrelated guard is not a regression control.

## Discovery and retention

Read `KeeForgeTests/AGENTS.md` and relevant support/fixture guidance before judging
overlap. Read `KeeForgeMac/README.md`'s testing table for affected Mac behavior, and
`.github/AGENTS.md`, `ci_scripts/README.md`, and actual target/scheme selection for
execution coverage. Read each candidate test in full, its production owner, callers,
relevant callees, overlapping suites, and history. Inspect dependency code or types
when a claim relies on a dependency contract.

Look for assertions that merely mirror implementation, expected values computed by
the same helper under test, assertion-free execution, mocks supplying the alleged
result, negative cases rejected by the wrong guard, duplicated scenarios at the same
boundary, stale test-only paths, or names claiming more than assertions establish.
These are investigation leads, not automatic deletion rules.

Preserve distinct guarantees:

- Shared iOS/Mac execution, compile guards, and Mac App Store/direct-build differences
  can expose different failures. Check actual CI routing and skips; compiling a test
  does not prove it executes. Mac UI tests are local-only.
- Parser/XML, encrypted-container, in-memory edit, save safety, and compatibility
  suites have separate owners in the test docs. Foreign-authored inputs and KeePassXC
  opening KeeForge output are independent evidence. In-process round trips cannot
  replace an external oracle; the external reader cannot inspect every preserved byte.
- Keep the compatibility harness's one assertion-bearing execution per artifact
  scenario, complete artifact inventory, and external expectations. Do not duplicate
  expensive KDF work to produce artifacts or shrink the matrix to improve timings.
- Security boundaries, defaults, migration/storage formats, localization catalogs,
  entitlements, extension membership, and release tooling can justify static or exact
  value checks. Judge the independent contract, not the assertion's appearance.
- Unit tests do not replace real focus/keyboard/window interactions or system AutoFill
  panels. Prefer headless tests where they reach the behavior; retain the smallest
  distinct UI proof. Screenshot captures are visual evidence, not assertion-free junk.

Do not delete a baseline failure because it is inconvenient. Separate product defects,
test defects, environment failures, skips, and unknown causes before recommending work.
Retain uncertain coverage pending evidence. Slow execution alone is not a removal case.

## Candidate evidence

For every proposed repair, consolidation, or deletion, record:

- Exact test name and location; what it actually detects, including unique edge cases.
- Production/support seam and its non-test callers, or evidence that it has none.
- The retained test(s) that cover the same failure, with assertions and execution
  destinations, or why no meaningful contract would be lost. Name any assertions
  that must move before removal.
- Relevant history explaining the test or seam; mark missing history as uncertainty.
- Production/support simplification actually unlocked, if any; do not manufacture one.
- Risk, focused validation commands, and whether each result is observed or proposed.

Prefer a few supported findings over a speculative deletion list. Keep the report
short: actionable findings, retained false positives that matter, verification limits,
and the next coherent batch. Put detailed evidence beside it under `scratch/`.

## Cleanup and validation

When cleanup is authorized, change one coherent production boundary at a time. Move
unique assertions into their retained owner before removing coverage or support. Honor
the stable-core restrictions; test cleanup is not permission to redesign crypto or
serialization. Update affected test maps and CI selections when ownership moves.

Run the smallest affected XCTest classes with `-only-testing:` using the repository's
device preference, global Xcode lock, and full-log requirements. Coordinate execution
centrally when agents are involved; do not edit files underneath an active test run.
Tie local and reused CI evidence to the actual tested revision, dirty source state,
target, and destination. Results from another revision do not validate this one;
missing provenance remains unverified. Inspect Git status after verification for
generated source or catalog changes and keep them separate from the audited revision.
Check the executed tests and skips as well as the verdict; zero executed tests is not
a pass. Expand verification only for affected contracts or unresolved concerns.

Use the compatibility suites and platform gates required by the repository when
creation, edits, parsing/writing, or save behavior changes. Validate the artifact gate
when its harness changes. Check Cloud partition validation when classes or schemes
move. Full UI suites require the user's explicit request. Finish with `git diff
--check` and inspect source, test, and support changes separately.

For an exhaustive subsystem campaign, read [campaign.md](references/campaign.md).
Otherwise stop after the requested scope. Report checks actually run, failures and
limits, preserved contracts, and remaining work; distinguish completed discovery from
validated cleanup. Follow local Git guidance for any authorized landing operations.
