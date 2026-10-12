# Extensions

**Scope:** small cross-cutting extensions and conformances that have no owning feature folder. Keep an extension next to its type unless several folders need it.

## Ownership

- `PlatformCompat.swift` is the view-layer iOS/macOS seam and is compiled into all four app and AutoFill targets. Per-modifier usage rules (`.macGroupedForm()`, `.macHelp()`, `.macFormFieldStyle()`, `.macLabelsHidden()`) are in `../Views/AGENTS.md`.
- `NavigationConformances.swift` is app-targets only.

## Invariants

- Add a shim to `PlatformCompat.swift` when a view needs a platform difference: either an iOS-only API given a macOS no-op/fallback so the call site compiles unchanged, or a `mac…` modifier that is a no-op on iOS. Do not scatter raw `#if os()` through Views. Raw conditionals are fine in Services and App where behaviour genuinely diverges.
- A `mac…` modifier must be inert on iOS. That is why `macHelp` and `macLabelsHidden` exist instead of plain `.help()` / `.labelsHidden()`, which change iOS VoiceOver output and placeholders.
- `KPEntry` and `KPGroup` are `Hashable` by `id` alone. `@Observable` therefore does not notify when a property is reassigned entries that differ only in content, and a view fed from it keeps the old copies. Resolve rows through `DatabaseViewModel.entry(withID:)`, as `EntryListView` does.
- `MacSheetMetrics.maxHeight` is sized to the main window's minimum height in `../App/KeeForgeApp.swift`; change them together. `macSheetFrame`'s `minHeight` must not exceed it.
- `Data.WritingOptions.atomicProtected` adds complete file protection on iOS only. macOS has no per-file Data Protection (setting a class fails), so FileVault is the at-rest protection there.

## See also

- `../Views/AGENTS.md`, `../App/AGENTS.md`
