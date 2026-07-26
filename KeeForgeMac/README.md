# KeeForgeMac Target

Configuration folder for the native macOS app target. It contains only `Info.plist` and `KeeForgeMac.entitlements` — there are no Mac-only sources here.

## Status: ON HOLD — Do Not Ship

The Mac app builds and tests green but **must not be released**. The authoritative status and pre-release TODO list live in `CHANGELOG.md` under `## macOS App (in development — ON HOLD, do not release until revisited)`. Log macOS work there, not under `## Unreleased` (which is iOS release notes).

## Target Map

- `KeeForgeMac` (app, `project.yml` ~line 83): compiles the shared `KeeForge/` tree (minus `LaunchScreen.storyboard`) plus selected `AutoFillExtension/` shells — see `KeeForge/README.md` for the exact sharing rules. `MARKETING_VERSION` is currently `1.10.1`, intentionally behind iOS (`1.10.4`); the Mac targets do not version-bump with iOS releases.
- `KeeForgeMacAutoFill` (extension, ~line 205): uses `AutoFillExtension/InfoMac.plist` and `AutoFillExtension/AutoFillExtensionMac.entitlements`; its shared-source list must stay literally identical to the iOS `KeeForgeAutoFill` allow-list (marked invariant in `project.yml`).
- `KeeForgeMacTests` (~line 421): has **no folder of its own** — it compiles the shared `KeeForgeTests/` sources, hosted inside `KeeForgeMac.app` (`TEST_HOST`/`BUNDLE_LOADER`).
- `KeeForgeMacUITests` (~line 397): does have its own folder and README (`KeeForgeMacUITests/`).

## Entitlements Gotchas

- App Sandbox + Hardened Runtime, user-selected read-write files, network client, app-scoped security bookmarks, and App Group `group.com.keevault.shared`.
- `keychain-access-groups` ordering matters: items stored without an explicit `kSecAttrAccessGroup` land in the **first** listed group, so `com.keevault.sharedkeychain` must stay first (see the comments in `AutoFillExtension/AutoFillExtensionMac.entitlements` and in `KeeForgeMac.entitlements` itself). The app additionally lists `com.microsoft.identity.universalstorage` (MSAL's macOS token cache — silent OneDrive token refresh depends on it); the Mac extension intentionally omits it.

## Info.plist Sync

Keep `Info.plist` in sync with `KeeForge/Info.plist` and `AutoFillExtension/InfoMac.plist`: OAuth URL schemes (`db-$(DROPBOX_APP_KEY)`, `msauth.$(PRODUCT_BUNDLE_IDENTIFIER)`), the ATS arbitrary-loads-plus-first-party-exceptions setup, kdbx document/UTType declarations, and the build-var keys `DropboxAppKey` / `OneDriveClientID` that the app reads at runtime.

## Security Posture

Per-platform security deltas vs iOS are documented in `docs/macos-security-notes.md` — a living doc (unlike most of `docs/`), so update it when Mac-relevant security behavior changes.

## Build And Test

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' \
  -only-testing:KeeForgeMacTests/DatabaseViewModelTests
```

Prefer the smallest `-only-testing:` slice, as with iOS. CI's manual `macos-build-and-test` job (`.github/workflows/ci.yml`) runs the same thing ad-hoc signed with entitlements stripped, because GitHub runners have no signing account.
