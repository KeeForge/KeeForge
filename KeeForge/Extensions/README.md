# Extensions Folder

Use this folder for small app-specific extensions and conformances that are shared across multiple views or models but do not justify their own feature folder.

## Current File

- `NavigationConformances.swift` keeps navigation state workable with the app's model types.

## Guidance

- Prefer keeping extensions next to the owning type unless they are genuinely cross-cutting.
- If a model stops working with `NavigationStack` or `NavigationPath`, this folder is one of the first places to check.
