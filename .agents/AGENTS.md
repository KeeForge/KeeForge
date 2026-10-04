# Repository Agent Workflows

Read the relevant skill before release or pre-release review work:

- `skills/prepare-release/SKILL.md` prepares a new version or patch's first candidate.
- `skills/respin-release/SKILL.md` replaces an unshipped candidate of the same version.
- `skills/ship-release/SKILL.md` publishes accepted artifacts. Shared release procedures live in `skills/prepare-release/references/`.
- `skills/pre-release-review/SKILL.md` runs a standalone review before candidate preparation. Reports use the main checkout's shared `scratch/pre-release/<UTC>__since-<baseline>__head-<SHA12>/report.md`; the report format lives in that skill's `references/report-format.md`.

For an explicitly requested SwiftUI review or UI change, use `skills/keeforge-swiftui/SKILL.md` during its adoption pilot. It adapts general SwiftUI guidance to KeeForge; folder-local contracts remain authoritative.

For product feedback triage, use `skills/triage-feedback/SKILL.md` to inspect evidence, classify concerns, and draft a response before any authorized follow-up.
