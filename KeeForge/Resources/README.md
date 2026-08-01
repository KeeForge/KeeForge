# Resources Folder

Static app resources live here.

## Current Contents

- `Assets.xcassets` — colors and image assets
- `LaunchScreen.storyboard` — launch screen UI
- `Localizable.xcstrings` — String Catalog (source language `en`, plus `de`, `fr`, and `es`) shared by the iOS and macOS app targets
- `InfoPlist.xcstrings` — localized Info.plist values (usage descriptions, bundle name) for both app targets

## Guidance

- Prefer asset-catalog additions over ad hoc image files.
- If a resource name is referenced from SwiftUI or tests, rename it carefully and update call sites together.
- App and extension plists plus entitlements live outside this folder; target wiring still happens through `../../project.yml` and the target-specific plist files.
