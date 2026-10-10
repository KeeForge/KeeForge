# KeeForgeMac Target

Configuration folder for the native macOS app target — only `Info.plist`, `KeeForgeMac.entitlements` (Mac App Store) and `KeeForgeMacDirect.entitlements` (direct download); no Mac-only sources.

## Status

The native Mac app shipped in v1.16.0 through the Mac App Store and as a notarized
direct download. macOS work now follows the ordinary changelog flow under
`## Unreleased` alongside iOS work. Release mechanics and evidence belong in the
release skill and candidate manifest rather than in `CHANGELOG.md`.

This file is reference material for working in the target: constraints, platform limits,
gotchas, and what a given change has to test.

## Target Map

- `KeeForgeMac` (app target in `project.yml`): requires macOS 15 and compiles the shared `KeeForge/` tree (minus `LaunchScreen.storyboard`) plus selected `AutoFillExtension/` shells (sharing rules: `KeeForge/README.md`). `MARKETING_VERSION` tracks iOS in lockstep — all four product targets carry the same version and build number, and one release bump covers them together. `PRODUCT_NAME` is `KeeForge`, so the bundle on disk is `KeeForge.app` (it was `KeeForgeMac.app` while the target was internal-only).
- `KeeForgeMacAutoFill` (extension): uses `AutoFillExtension/InfoMac.plist` and `AutoFillExtension/AutoFillExtensionMac.entitlements`; its shared-source list must stay literally identical to the iOS `KeeForgeAutoFill` allow-list (marked invariant in `project.yml`).
- `KeeForgeMacTests`: **no folder of its own** — compiles the shared `KeeForgeTests/` sources, hosted in `KeeForge.app` (`TEST_HOST`/`BUNDLE_LOADER`).
- `KeeForgeMacUITests`: has its own folder and `AGENTS.md` (`KeeForgeMacUITests/`).

## Entitlements Gotchas

- App Sandbox + Hardened Runtime, user-selected read-write files, network client, app-scoped security bookmarks, App Group `group.com.keevault.shared`.
- `keychain-access-groups`: the app and the extension both list exactly one group, `com.keevault.sharedkeychain`. Ordering matters the moment a second one is added — items stored without an explicit `kSecAttrAccessGroup` land in the **first** listed group, so the shared group must stay first (see comments in both entitlements files). MSAL's macOS token cache group (`com.microsoft.identity.universalstorage`) is deliberately absent: macOS ships WebDAV only, so nothing authenticates through MSAL. Re-enabling OneDrive means adding it back *and* regenerating the Developer ID profiles, which embed the entitlements.

## Info.plist Sync

Keep `Info.plist` in sync with `KeeForge/Info.plist` and `AutoFillExtension/InfoMac.plist`, minus the cloud OAuth surface: the Mac app builds neither cloud SDK, so it deliberately declares **no** `db-*`/`msauth.*` URL scheme and none of the `DropboxAppKey`/`OneDriveClientID`/`OneDriveRedirectURI` keys the iOS plist carries (`URLSchemeFormatTests` pins their absence). What must stay in sync: the `otpauth` scheme that routes incoming verification-code links into `TOTPEnrollmentDestinationView`, the ATS arbitrary-loads-plus-first-party-exceptions setup, and kdbx document/UTType declarations. `DropboxAppKey`, `OneDriveClientID`, and `OneDriveRedirectURI` are explicitly excluded from the Mac plist and runtime/configuration surface.

## Security Posture

The [macOS security model](SECURITY.md) covers secrets, shared storage, lock behavior, platform limits, extension entitlements, and update trust. Keep it current when Mac-relevant security behavior changes. Release procedures live in [the direct-distribution release reference](../.agents/skills/prepare-release/references/direct-distribution.md).

## Build And Test

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' \
  -only-testing:KeeForgeMacTests/DatabaseViewModelTests
```

Prefer the smallest `-only-testing:` slice, as with iOS. The `macos-unit-tests` job in `.github/workflows/pr-tests.yml` runs the same suite on every PR and is a required status check on `main` and `release/**`, and `.github/workflows/macos-rc-tests.yml` runs it on each `rc/*` tag; both are ad-hoc signed with entitlements stripped (no signing account on runners). `ci.yml`'s `macos-build-and-test` remains for manual dispatch.

## What Mac Work Has To Test

The rule of thumb from `../AGENTS.md` ("macOS Test Strategy") in the form a change author needs: find the row your change is in, and write what it names before you call the change done. Mac XCUITest is the last resort on every row — it needs an unlocked login session, grabs real screen and input focus, and serializes against every other Xcode run on the machine.

| What you changed | What must exist when you are done |
| --- | --- |
| Behavior in a view model, service, or model reachable on macOS | A `KeeForgeTests/` test. It compiles into `KeeForgeMacTests` for free, so this is the cheapest coverage there is and the default answer. |
| Behavior that only exists on macOS (`#if os(macOS)` in a view model or service) | A `#if os(macOS)` test in `KeeForgeTests/`, guarded the way `MacLockMonitorTests` and `CredentialProviderShellMacTests` are. It runs in `KeeForgeMacTests` only, and CI runs it on every PR. |
| A Mac-only interaction with no view-model seam (keyboard routing, first-responder handling, window lifecycle) | First try to give it a seam and test the seam. If it genuinely cannot have one, add the smallest possible case to `../KeeForgeMacUITests/MacSmokeUITests.swift` — and say in the test why a unit test could not reach it. The unlock password field is the worked example: `MacUnlockPasswordFieldTests` covers its focus lifecycle and field-editor routing headlessly, and only the real sidebar-click hand-off stays in `MacSmokeUITests`. |
| Layout or visual polish (sizing, spacing, hover, empty states) | No new assertions. Re-run `MacScreenshotAuditUITests` and look at the captures; add a screen to that walk if the change introduced one. |
| A SwiftUI view the macOS AutoFill shell hosts (`AutoFillExtension/`) | A manual pass in a real AutoFill panel — nothing automated reaches these views. Check first that every action is drawn *inside* the view: `.toolbar` and `.searchable` go to the window's `NSToolbar` on macOS, and the system credential-provider window has none, so a toolbar-only Cancel compiles, tests green, and ships a panel with no exit. See `../AutoFillExtension/AGENTS.md`. |
| An accessibility identifier | Update every suite that names it, in the same change — `../KeeForgeUITests/` and `../KeeForgeMacUITests/` share identifiers by convention. |
| User-facing text | Translations for every shipped locale plus a `LocalizationTests` run; the Mac targets use the same four catalogs the iOS ones do. |
| Parser, writer, protected fields, unknown XML, or any save path | `../KeeForgeTests/KDBXCompatibilityTests.swift`, plus the compatibility gate per platform: `KDBX_COMPAT_SCHEME=KeeForgeMac ci_scripts/run_kdbx_compatibility_gate.sh`. |
| Anything writing to the system credential identity store | A `KeeForgeTests/CredentialIdentityStoreManagerTests.swift` case against `FakeCredentialIdentityStore` with `supportsIncrementalUpdatesValue = false`, alongside the incremental one. macOS takes that branch for every write. |
| Entitlements, the App Group container, the AutoFill extension boundary, or Sparkle | [`SECURITY.md`](SECURITY.md) refreshed against what actually shipped, and `AppGroupGuardrailTests` re-run if the container's write surface moved. |

Two standing constraints behind the table:

- **`KeeForgeMacUITests` never runs in CI.** It needs an unlocked, active login session no runner has, so it is a local pre-release step only (`.github/AGENTS.md`). A behavior whose only coverage is a Mac UI test is, for CI purposes, uncovered — which is the whole reason the first column pushes so hard toward view models.
- **`KeeForgeMacTests` has no folder.** It compiles `../KeeForgeTests/`, so every test you add there costs both platforms' runtime. Keep macOS-only cases behind `#if os(macOS)` rather than branching inside a shared test.

## Distribution Channels

One target, two channels, chosen when the project is generated rather than when it is built:

- `xcodegen generate` — **Mac App Store**: no Sparkle in the binary and StoreKit tip jar. Adding macOS to the existing App Store Connect app record established universal purchase with iOS; there is no separate toggle. This is the default, so every ordinary workflow and every CI job builds this.
- `xcodegen generate --spec project-direct.yml` — **Developer ID direct download**: links Sparkle, compiles `KEEFORGE_DIRECT_DOWNLOAD`, shows GitHub Sponsors instead of the tip jar, never calls StoreKit. It is also the only spec that selects `KeeForgeMacDirect.entitlements` and sets `SUEnableInstallerLauncherService`: a sandboxed app cannot submit Sparkle's installer job itself, and without the `-spks`/`-spki` mach-lookup exceptions an update downloads and verifies and then hangs forever at the progress window. Those two entitlement files must stay identical apart from that one key. `ci_scripts/build_mac_direct.sh` drives it and restores the App Store spec on exit.

Two specs rather than two targets: both channels ship an app named `KeeForge.app` (the executable name is inside the signature and cannot be renamed afterwards), and two targets producing the same product path is a hard Xcode error. Separate specs also make the channels mutually exclusive by construction — an App Store build must never contain an updater.

Read the channel at runtime through `DistributionChannel` only. `SUFeedURL` / `SUPublicEDKey` in `Info.plist` come from the `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` build settings and are empty in the App Store build, which ignores them.
