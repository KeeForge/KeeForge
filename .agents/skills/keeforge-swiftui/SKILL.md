---
name: keeforge-swiftui
description: Review KeeForge SwiftUI views for accessibility, state, navigation, and rendering problems, or apply that guidance to a requested UI change. Invoke explicitly during the adoption pilot.
license: MIT
---

# KeeForge SwiftUI

Apply this skill to the requested views or diff. Review requests are read-only unless the user also asks for fixes. Do not expand a UI task into a repository-wide modernization.

## Start with the local contract

Read the applicable folder guidance and [shared UI rules](../../../KeeForge/Views/README.md). Repository and local instructions take precedence over this skill. Read [Mac guidance](../../../KeeForgeMac/README.md) or [AutoFill guidance](../../../AutoFillExtension/AGENTS.md) when those surfaces are affected.

Check the actual target settings in [project.yml](../../../project.yml). The adoption baseline is iOS 18, macOS 15, Swift 6 language mode, and complete concurrency checking. Language mode does not identify the compiler version. Verify SDK and runtime availability before recommending newer APIs; do not raise deployment targets as cleanup.

Load only the reference relevant to the task:

- [Accessibility and platform interaction](references/accessibility.md): labels, text scaling, motion, selection, keyboard behavior, and platform-hosted controls.
- [State, navigation, and concurrency](references/state.md): ownership, bindings, presentation, cancellation, and actor boundaries.
- [View structure and performance](references/views.md): view identity, observation scope, rendering work, and API modernization.

For text changes, follow [resource guidance](../../../KeeForge/Resources/README.md) and the repository's translation, catalog normalization, and localization-test rules. Preserve the existing catalog key convention. For implementation work, use the existing verification rules, including the Mac test-strategy table; this skill introduces no new build or test commands.

## Review standard

Trace a suspected problem through its owner and callers before reporting it. A syntax match is a review lead, not proof of a bug. Preserve intentional platform bridges and stable accessibility identifiers. Core crypto, parsing, secret lifetimes, and save behavior are outside routine UI cleanup; read those owners when needed to explain a UI failure, without expanding the authorized edit scope.

For each confirmed finding, give a file and line, the affected platform and user-visible consequence, evidence, and the smallest behavior-preserving correction. Label an unverified runtime concern as a verification candidate and say what observation would settle it. Keep optional improvements separate from defects; omit preference-only churn. Do not prescribe a fix when it would change behavior you have not traced.

Finish with the most impactful findings, what was inspected or tested, and any material verification limits. A review with no confirmed findings is valid. Save reports in the main checkout's gitignored `scratch/` only when a report is requested or useful for an agreed pilot; follow the repository's scratch-location rule.

## Provenance and maintenance

Adapted from Paul Hudson's SwiftUI Pro. See [provenance](references/provenance.md) for the pinned upstream revision, local changes, and update procedure; retain [LICENSE](LICENSE) with this skill. Upstream is reference material, not a runtime dependency.
