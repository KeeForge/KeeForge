# Extensions

**Scope:** small cross-cutting extensions and conformances that have no owning feature folder. Keep an extension next to its type unless several folders need it.

## Ownership

- `PlatformCompat.swift` is the view-layer iOS/macOS seam and is compiled into all four app and AutoFill targets. Per-modifier usage rules (`.macGroupedForm()`, `.macHelp()`, `.macFormFieldStyle()`, `.macLabelsHidden()`) are in `../Views/AGENTS.md`.
- `NavigationConformances.swift` is app-targets only.

## Invariants

- A view that exists on one platform is wrapped file-wide in `#if os()`. When a view both platforms share needs a difference, add a shim to `PlatformCompat.swift` rather than an inline `#if os()`: either an iOS-only API given a macOS no-op/fallback so the call site compiles unchanged, or a `mac…` modifier that is a no-op on iOS. Raw conditionals are fine in Services and App where behaviour genuinely diverges.
- `onAppDidBecomeActive` follows scene activation on iOS and application activation notifications on Mac, where the SwiftUI content has no scene. It refreshes UI status without introducing a lock trigger.
- A `mac…` modifier must be inert on iOS. That is why `macHelp` and `macLabelsHidden` exist instead of plain `.help()` / `.labelsHidden()`, which change iOS VoiceOver output and placeholders.
- `MacSheetMetrics.maxHeight` is sized to the database window's minimum height and the Databases window's content height in `../../KeeForgeMac/App/`; change them together. `macSheetFrame`'s `minHeight` must not exceed it.
- `Data.WritingOptions.atomicProtected` adds complete file protection on iOS only. macOS has no per-file Data Protection (setting a class fails), so FileVault is the at-rest protection there.

## See also

- `../Views/AGENTS.md`, `../App/AGENTS.md`
