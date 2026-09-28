# Pre-release review report contract (version 1)

This is the report contract for the standalone pre-release review skill.
Use one human-readable Markdown report with YAML frontmatter, not a second JSON record.

## Location and naming

The canonical root is `<primary-checkout>/scratch/pre-release/`. Resolve the primary
checkout from the first `worktree` entry in `git worktree list --porcelain`; on Tan's Mac
this is `/Users/tan/src/KeeForge/scratch/pre-release/`. Use this shared location even
when reviewing in a linked worktree, so retiring that worktree does not lose the review.
If the primary checkout is unavailable, use an explicit user-supplied report location
and disclose it; do not silently scatter reports across worktrees.

Each new review gets a directory:

`YYYY-MM-DDTHHMMSSZ__since-vMAJOR.MINOR.PATCH__head-SHA12/`

Use UTC creation time, the baseline tag, and the initial target's first 12 SHA characters.
For an explicit commit baseline without a release tag use `since-SHA12`. Sanitize any
custom ref rather than using slashes in a directory name. If a name exists, append
`__2`, `__3`, etc.; never overwrite an independent review.

- `report.md` — titled **KeeForge Pre-release Review**; the authoritative current decision summary.
- `evidence/` — supporting verification notes, follow-up history, and small non-secret
  screenshots or extracts as needed. Keep detailed evidence out of the report body.

Link large Xcode logs and result bundles at their normal repository-prescribed locations.
Reports and evidence stay untracked: `scratch/` is already ignored. Do not force-add them.
Do not include credentials, tokens, personal vault contents, or unredacted secrets in
commands, output excerpts, or screenshots.

Example:

`/Users/tan/src/KeeForge/scratch/pre-release/2026-09-28T031500Z__since-v1.20.0__head-0123456789ab/report.md`

The example is illustrative, not a claim about the current release or an existing review.
Follow-ups keep the directory name, refresh the concise report, and preserve history in
`evidence/follow-ups.md`; frontmatter records the latest reviewed commit. No `latest`
symlink or duplicated summary file is needed.

## Frontmatter

Fill these fields with actual evidence. SHA fields contain full commit hashes. Times
use ISO 8601 UTC. `planned_version` may be null; review does not require choosing a version.

```yaml
---
schema_version: 1
review_id: "<directory name>"
created_at: "<UTC timestamp>"
updated_at: "<UTC timestamp>"
review_status: "in-progress"
repository: "<repository identity, without credentials>"
source_checkout: "<absolute path>"
baseline_ref: "<shipped tag or explicit ref>"
baseline_commit: "<full SHA>"
initial_target_commit: "<full SHA>"
reviewed_through_commit: "<full SHA or null until completed>"
working_tree: "clean"
planned_version: null
website:
  source_checkout: "<absolute path or null>"
  source_commit: "<full SHA or null>"
  working_tree: "clean"
  live_urls: []
  inspected_at: null
  status: "not-reviewed"
recommendation: "pending"
---
```

Allowed values:

- `review_status`: `in-progress`, `complete`, `incomplete`.
- `working_tree` (both repositories): `clean`, `dirty`, `unavailable`. Record dirty
  paths in supporting evidence and surface any effect on confidence; never label a dirty-source test as an
  exact-commit pass. `reviewed_through_commit` describes committed review coverage only.
- `website.status`: `reviewed`, `partial`, `unavailable`, `not-reviewed`.
- `recommendation`: `pending`, `ready-for-release-process`, `address-findings`,
  `insufficient-evidence`. This is advice, not release authorization.

Use YAML null, not the string `"null"`, for unknown optional values. Keep frontmatter
small and do not repeat its metadata in the body unless it affects a decision.

## Human-facing report

The report must be short and concise. Include only actionable or noticeable findings,
material uncertainty, and useful manual checks. Aim for at most about 500 words in the
body for a typical review, much less for a clean review. This is a brevity target, not
a quota or permission to omit important findings. Prefer compact bullets to wide tables.

Do not include a chronological audit trail, lists of files or commits inspected,
clean-area summaries, routine passing checks, exhaustive test/coverage tables, boilerplate
release guidance, speculative low-value suggestions, or empty sections. The breadth of
the audit belongs in the work, not the length of the report. Apply the same rule to the
final chat response. Omit headings that have nothing useful beneath them.

### Verdict

One or two sentences: readiness recommendation and the most important action or risk.
If there are no material findings, say so without enumerating everything that passed.
Review completeness does not imply findings are resolved or manual checks have run.

### Findings requiring attention

Only include findings that change a release decision, call for a concrete worthwhile
action, or describe noticeable user impact. Order by urgency; label `fix-before-rc`,
`coordinate-for-launch`, or `follow-up`. Use stable IDs `F-001`, etc.

Each finding should fit in a compact bullet or short paragraph: what is wrong, affected
platforms/locales when relevant, impact, recommended action, and a precise evidence link.
Label suspected or unverified claims explicitly. Include status only where useful, such
as a deferred risk. Keep detailed reproduction and verification instructions in linked
evidence when they would overwhelm the finding.

Do not invent findings to populate the structure, automatically resolve them because
files changed, or infer owner acceptance from silence. Combine repeated symptoms of the
same cause. Remove resolved findings from the current summary unless their resolution
still affects the release decision; preserve their evidence and history separately.

### Manual checks

List only valuable checks prompted by changed behavior or an important automation gap,
ordered by priority, with stable IDs `M-001`, etc. Keep each item executable: platform,
necessary setup, action, expected result, and whether it needs the candidate artifact.
Include approximate effort when useful for planning. Link a detailed procedure only when
the setup or steps cannot fit concisely. Avoid generic regression checklists.

Pending checks are `not-run`; never imply success from merely writing a plan. Retain
failed or blocked checks needing attention. Keep completed check details and exact build
identity in supporting evidence rather than accumulating passed items in this section.

### Material limitations

Mention only missing access, unchecked areas, dirty-source evidence, or verification
failures that materially limit confidence, with the next useful action. Do not hide
incomplete coverage behind a clean verdict. Do not duplicate a limitation already
explained in a finding.

## Supporting evidence

Keep enough evidence to substantiate findings, establish review coverage, and support
later follow-ups. Use `evidence/verification.md` for nontrivial test evidence or concise
coverage notes when needed; do not create a second verbose report or log every read.
Record commands, actual source SHA/dirty state, destination, available executed/skipped
counts, result, and log/result-bundle/CI links outside the human-facing summary.

Distinguish `passed`, `failed`, `infrastructure-failure`, `skipped`, and `not-run`.
Use `unknown` when counts are unavailable, not zero. Retain relevant assertion coverage,
reproduction steps, resolution evidence, and explicit owner decisions where needed.
Link this evidence from the finding or limitation it supports; do not surface unrelated
details merely because they were collected.

## Follow-up reviews

Before replacing earlier findings, preserve them in `evidence/follow-ups.md`. Append
timestamped entries identifying old/new target SHAs, material finding transitions, and
supporting evidence. Update frontmatter and the concise current report after reviewing
the delta and affected contracts. Do not append history to `report.md` or repeat it in
the final response.
