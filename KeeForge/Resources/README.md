# Resources Folder

Static app resources live here.

## Current Contents

- `Assets.xcassets` — colors and image assets
- `LaunchScreen.storyboard` — launch screen UI
- `Localizable.xcstrings` — String Catalog (source language `en`, plus `de`, `fr`, `es`, `zh-Hans`, and `zh-Hant`) shared by the iOS and macOS app targets
- `InfoPlist.xcstrings` — localized Info.plist values (usage descriptions, bundle name) for both app targets
- `PrivacyInfo.xcprivacy` — Apple privacy manifest for both app targets (required-reason API declarations, no tracking); the extensions carry their own copy in `../../AutoFillExtension/`. Update it when adding required-reason API usage (UserDefaults, file timestamps, disk space, boot time, active keyboards) or any off-device data flow

## Guidance

- Prefer asset-catalog additions over ad hoc image files.
- If a resource name is referenced from SwiftUI or tests, rename it carefully and update call sites together.
- App and extension plists plus entitlements live outside this folder; target wiring still happens through `../../project.yml` and the target-specific plist files.

## Catalog Mechanics

- Four catalogs: `Localizable.xcstrings` + `InfoPlist.xcstrings` here, mirrored under `../../AutoFillExtension/`; the same four also serve the macOS targets.
- When adding a new locale, also translate the root `README.md` and `CONTRIBUTING.md` (translations live in `../../docs/i18n/` as `README.<locale>.md` and `CONTRIBUTING.<locale>.md`, and link back to root paths with `../../`; folder-local READMEs and the rest of the developer docs stay English-only) and the separate `keeforge.com` website repo, which needs the same locale coverage.
