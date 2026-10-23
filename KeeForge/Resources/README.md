# Resources Folder

Static app resources live here.

## Current Contents

- `Assets.xcassets` — colors and image assets
- `LaunchScreen.storyboard` — launch screen UI
- `Localizable.xcstrings` — String Catalog (source language `en`, plus `de`, `fr`, `es`, `zh-Hans`, `zh-Hant`, `ja`, `it`, and `ru`) shared by the iOS and macOS app targets
- `InfoPlist.xcstrings` — localized Info.plist values (usage descriptions, bundle name) for both app targets
- `PrivacyInfo.xcprivacy` — Apple privacy manifest for both app targets (required-reason API declarations, no tracking); the extensions carry their own copy in `../../AutoFillExtension/`. Update it when adding required-reason API usage (UserDefaults, file timestamps, disk space, boot time, active keyboards) or any off-device data flow

## Passphrase Wordlist

`eff_large_wordlist.txt` is the unchanged 7,776-entry EFF Long Wordlist by Joseph Bonneau and the Electronic Frontier Foundation, downloaded from <https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt>. It ships in the apps and both extensions, with no runtime download. EFF publishes original material under [CC BY 4.0](https://www.eff.org/copyright); attribution is also shown in Acknowledgments. `PasswordGenerator` skips its four hyphenated entries so word boundaries stay clear with a `-` separator, leaving 7,772 words. When updating the upstream list, verify its licensing and update the pinned digest and word counts in `PasswordGeneratorTests`.

## Guidance

- Prefer asset-catalog additions over ad hoc image files.
- If a resource name is referenced from SwiftUI or tests, rename it carefully and update call sites together.
- App and extension plists plus entitlements live outside this folder; target wiring still happens through `../../project.yml` and the target-specific plist files.

## Catalog Mechanics

- Four catalogs: `Localizable.xcstrings` + `InfoPlist.xcstrings` here, mirrored under `../../AutoFillExtension/`; the same four also serve the macOS targets.
- Adding a locale follows the checklist in `../../AGENTS.md` (Localization). Translated docs link back to root paths with `../../`; folder-local READMEs and the rest of the developer docs stay English-only.
