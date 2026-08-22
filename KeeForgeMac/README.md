# KeeForgeMac Target

Configuration folder for the native macOS app target — only `Info.plist` and `KeeForgeMac.entitlements`; no Mac-only sources.

## Status: Preparing The First Release

No longer on hold — the Mac app is being brought to a shippable state, but it **has not shipped yet**. Authoritative status and the remaining pre-release checklist: `CHANGELOG.md` under `## macOS App`. Log macOS work there, not under `## Unreleased` (iOS release notes).

Still open before it can ship: slice 07 distribution (`docs/specs/2026-07-12-macos-port/07-distribution.md`) — Sparkle, notarization, Developer ID signing and the MAS-vs-direct channel seam — plus the manual QA matrix and the unresolved "AutoFill provider missing from System Settings" bug, whose next diagnostic step needs a distribution-signed build.

## Target Map

- `KeeForgeMac` (app target in `project.yml`): compiles the shared `KeeForge/` tree (minus `LaunchScreen.storyboard`) plus selected `AutoFillExtension/` shells (sharing rules: `KeeForge/README.md`). `MARKETING_VERSION` tracks iOS in lockstep — all four product targets carry the same version and build number, and one release bump covers them together. `PRODUCT_NAME` is `KeeForge`, so the bundle on disk is `KeeForge.app` (it was `KeeForgeMac.app` while the target was internal-only).
- `KeeForgeMacAutoFill` (extension): uses `AutoFillExtension/InfoMac.plist` and `AutoFillExtension/AutoFillExtensionMac.entitlements`; its shared-source list must stay literally identical to the iOS `KeeForgeAutoFill` allow-list (marked invariant in `project.yml`).
- `KeeForgeMacTests`: **no folder of its own** — compiles the shared `KeeForgeTests/` sources, hosted in `KeeForge.app` (`TEST_HOST`/`BUNDLE_LOADER`).
- `KeeForgeMacUITests`: has its own folder and README (`KeeForgeMacUITests/`).

## Entitlements Gotchas

- App Sandbox + Hardened Runtime, user-selected read-write files, network client, app-scoped security bookmarks, App Group `group.com.keevault.shared`.
- `keychain-access-groups` ordering matters: items stored without an explicit `kSecAttrAccessGroup` land in the **first** listed group, so `com.keevault.sharedkeychain` must stay first (see comments in both entitlements files). The app also lists `com.microsoft.identity.universalstorage` (MSAL's macOS token cache; silent OneDrive token refresh depends on it); the Mac extension intentionally omits it.

## Info.plist Sync

Keep `Info.plist` in sync with `KeeForge/Info.plist` and `AutoFillExtension/InfoMac.plist`: OAuth URL schemes (`db-$(DROPBOX_APP_KEY)`, `msauth.$(PRODUCT_BUNDLE_IDENTIFIER)`), the `otpauth` scheme that routes incoming verification-code links into `TOTPEnrollmentDestinationView`, the ATS arbitrary-loads-plus-first-party-exceptions setup, kdbx document/UTType declarations, and the build-var keys `DropboxAppKey` / `OneDriveClientID` the app reads at runtime.

## Security Posture

Per-platform security deltas vs iOS: `docs/macos-security-notes.md` — a living doc; update it when Mac-relevant security behavior changes.

## Build And Test

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' \
  -only-testing:KeeForgeMacTests/DatabaseViewModelTests
```

Prefer the smallest `-only-testing:` slice, as with iOS. The `macos-unit-tests` job in `.github/workflows/pr-tests.yml` runs the same suite on every PR, and `.github/workflows/macos-rc-tests.yml` runs it on each `rc/*` tag; both are ad-hoc signed with entitlements stripped (no signing account on runners). `ci.yml`'s `macos-build-and-test` remains for manual dispatch.
