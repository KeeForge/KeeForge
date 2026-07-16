# Extensions Folder

Use this folder for small app-specific extensions and conformances that are shared across multiple views or models but do not justify their own feature folder.

## Current Files

- `NavigationConformances.swift` keeps navigation state workable with the app's model types.
- `PlatformCompat.swift` is the shared iOS/macOS compatibility shim for the macOS port: `PlatformImage` (`UIImage`/`NSImage`) + `Image(platformImage:)`, UIKit semantic color names on `NSColor`, and macOS no-op/fallback shims for `navigationBarTitleDisplayMode`, `.topBarLeading`/`.topBarTrailing`, `.insetGrouped`, `.navigationBarDrawer` search placement, `keyboardType`, and `textInputAutocapitalization`. Target membership: KeeForge, KeeForgeAutoFill, KeeForgeMac. Prefer adding view-layer platform compatibility here over scattering raw `#if os()` in Views.

## Guidance

- Prefer keeping extensions next to the owning type unless they are genuinely cross-cutting.
- If a model stops working with `NavigationStack` or `NavigationPath`, this folder is one of the first places to check.
