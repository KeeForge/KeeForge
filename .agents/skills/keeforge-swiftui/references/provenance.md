# Provenance

This skill adapts selected guidance from **SwiftUI Pro**, created by **Paul Hudson** and distributed under the MIT license.

- Repository: https://github.com/twostraws/SwiftUI-Agent-Skill
- Reviewed revision: `be297ff80dddec529af1f9b1f1f114aab6c9d11c`
- Source entry point: https://github.com/twostraws/SwiftUI-Agent-Skill/blob/be297ff80dddec529af1f9b1f1f114aab6c9d11c/swiftui-pro/SKILL.md
- Source references: `accessibility.md`, `api.md`, `data.md`, `design.md`, `hygiene.md`, `navigation.md`, `performance.md`, `swift.md`, and `views.md` under that revision's `swiftui-pro/references/`.
- Upstream license: https://github.com/twostraws/SwiftUI-Agent-Skill/blob/be297ff80dddec529af1f9b1f1f114aab6c9d11c/LICENSE

## Local adaptation

The upstream guides are condensed into three task-specific references. This version uses KeeForge's deployment targets and existing folder contracts, preserves required platform bridges and custom binding semantics, and distinguishes observed defects from modernization preferences and unverified runtime concerns. It omits SwiftData/CloudKit advice and blanket rules about type-per-file organization, GCD, bindings, and newest APIs. Localization, core security boundaries, and verification remain owned by repository guidance. Codex implicit invocation is disabled for the adoption pilot; other agents should invoke the skill explicitly as described in its entry point.

## Updating

Compare upstream changes against the pinned revision and keep only guidance relevant to KeeForge. Verify changed API claims against Apple/Swift primary documentation and current project settings. Review any local exception before removing it, and retain the copyright/license notice. Update this revision and adaptation record with accepted changes; do not automatically overwrite local guidance with upstream files. Re-run skill validation and a focused behavioral pilot when the review rules materially change.
