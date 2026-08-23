# Extensions Folder

Use this folder for small app-specific extensions and conformances that are shared across multiple views or models but do not justify their own feature folder.

## Current Files

- `NavigationConformances.swift` keeps navigation state workable with the app's model types.
- `PlatformCompat.swift` is the shared iOS/macOS compatibility shim for the macOS port: `PlatformImage` (`UIImage`/`NSImage`) + `Image(platformImage:)`, `PlatformTextContentType`, UIKit semantic color names on `NSColor`, `Data.WritingOptions.atomicProtected`, macOS no-op/fallback shims for `navigationBarTitleDisplayMode`, `.topBarLeading`/`.topBarTrailing`, `.insetGrouped`, `.navigationBarDrawer` search placement, `keyboardType`, and `textInputAutocapitalization`, plus `macSearchFocusedCompat` (macOS only; `searchFocused` availability shim), `macHoverHighlight` (row hover highlight through `listRowBackground`, no-op on iOS), `macSelectableRowHover` (the same affordance for a row inside a `List(selection:)`, drawn behind the row's own content — `listRowBackground` is what such a list paints its selection with, so tinting through it would leave a selected row unmarked), `macSheetFrame`, `macHelp` (hover tooltip for icon-only controls — deliberately not plain `.help()`, which on iOS becomes the VoiceOver hint and would change what iOS reads out next to an existing `accessibilityLabel`), `macGroupedForm` (`.formStyle(.grouped)` on macOS, so sheeted editors get the insets and grouped backgrounds the Settings tabs already have instead of macOS's default edge-to-edge `.columns` style), `macFormFieldStyle` (visible text-field bezel on macOS, which a grouped `Form` otherwise omits), and `macLabelsHidden` (hides a control's built-in label on macOS only — a `Form` row that captions its own field gets a second, right-aligned label there, and applying `.labelsHidden()` unconditionally would cost iOS its `TextField` placeholder). Target membership: all four (KeeForge, KeeForgeMac, KeeForgeAutoFill, KeeForgeMacAutoFill). Prefer adding view-layer platform compatibility here over scattering raw `#if os()` in Views.

## Guidance

- Prefer keeping extensions next to the owning type unless they are genuinely cross-cutting.
- If a model stops working with `NavigationStack` or `NavigationPath`, this folder is one of the first places to check.
