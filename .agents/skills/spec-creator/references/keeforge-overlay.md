# KeeForge Overlay

Apply when the active repo is KeeForge. Additive on top of `SKILL.md`. Coding agents already read `AGENTS.md`; this file only adds what spec authoring needs beyond that.

## Extra clarify questions

Pull these into the Phase 3 mix when relevant — they almost always beat a generic equivalent:

- **Stable core touch?** Does the feature plausibly modify any of the files `AGENTS.md` lists as stable core? If yes, the epic must justify it.
- **AutoFill target?** Main app, extension, or both? Shared code stays extension-safe.
- **Lock state?** What happens if the database is locked when triggered, or locks mid-flow?
- **Session secrets?** Does the feature read decrypted secrets? It must go through `EncryptedValue`.

## Per-slice required additions

Every slice file under this overlay must include:

- **Target membership** — which targets each new/changed file belongs to. Shared files list every target.
- **project.yml impact** — `No changes` or a bullet list, ending with `Run xcodegen generate`.
- **Accessibility identifiers** (view-layer slices only) — new identifiers added, existing preserved.
- **CHANGELOG entry** — the one-line entry to add under `## Unreleased`.

## Research source preferences

When research is warranted, prefer in order: Apple Developer Documentation, Apple HIG, the relevant RFC/format spec, then KeePassium and Strongbox as iOS KeePass comparables. Cite as `[title](URL)`.
