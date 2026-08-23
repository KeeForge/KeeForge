# KeeForgeMac Target

Configuration folder for the native macOS app target — only `Info.plist` and `KeeForgeMac.entitlements`; no Mac-only sources.

## Status: Preparing The First Release

No longer on hold — the Mac app is being brought to a shippable state, but it **has not shipped yet**. Authoritative status and the remaining pre-release checklist: `CHANGELOG.md` under `## macOS App`. Log macOS work there, not under `## Unreleased` (iOS release notes).

Still open before it can ship: the credential-dependent half of slice 07 (`docs/specs/2026-07-12-macos-port/07-distribution.md`) — a Developer ID certificate, hand-made Developer ID profiles, notarization credentials, an EdDSA key and appcast hosting — plus the manual QA matrix. The in-repo plumbing for both channels is in place (see "Distribution Channels" below).

## AutoFill Provider Missing From System Settings

Long tracked as an unexplained bug. The in-repo registration surface is **not** the cause and has been re-verified: `InfoMac.plist` carries the right `NSExtensionPointIdentifier` (`com.apple.authentication-services-credential-provider-ui`), the principal class resolves (`KeeForgeMacAutoFill.CredentialProviderViewController`, matching the `#if os(macOS)` shell), the package type is `XPC!`, and the capability keys are the two that exist on the macOS 14 floor. `pluginkit` sees the built extension and registers it.

The cause is a **bundle-identifier collision with the iOS app running on Apple Silicon**. The "Designed for iPad" build installed from the App Store lands at `/Applications/KeeForge.app` as a wrapped bundle, and inside it `Wrapper/KeeForge.app/PlugIns/KeeForgeAutoFill.appex` claims `com.keevault.app.autofill` — the same extension identifier as the native Mac extension, under the same app identifier `com.keevault.app`. macOS resolves a credential provider by identifier, so the iOS wrapper shadows the native extension: the Mac appex is registered but never the one AuthenticationServices resolves, and an iOS-wrapped credential provider is not listed in the Mac AutoFill pane. The symptom is exactly "correct registration and entitlements, still absent".

Reproduce the diagnosis on any Mac:

```bash
pluginkit -mAvvv -p com.apple.authentication-services-credential-provider-ui
mdfind "kMDItemCFBundleIdentifier == 'com.keevault.app'"
```

Every extra bundle claiming `com.keevault.app` is a candidate shadow. On a development Mac the list also picks up stale `/Applications` copies from earlier builds and every DerivedData product, which are noise of the same kind.

What this means for the release: it is the same question as "what happens to the iOS app on Apple Silicon Macs", and it is answered the same way — **withdraw Mac availability for the iOS app** when the native app ships, so exactly one bundle owns the identifier. Until that is done in App Store Connect, verify Mac AutoFill on a Mac that does not have the iOS app installed. Users who migrate need the databases and bookmarks in their iOS container accounted for; that migration story is a release task, not a code one.

Not yet ruled out, because it needs a certificate that does not exist yet: whether a distribution-signed build behaves differently from the development-signed one. Re-check after the Developer ID cert exists, on a clean Mac.

## Moving Off The iOS App On A Mac

Withdrawing Mac availability for the iOS app stops new installs; it does not remove the ones already there, and Apple gives no migration path between the two containers. So the release needs an answer for a user who has been running "Designed for iPad" KeeForge on a Mac and now installs the native app. What actually has to move:

- **Local databases** live inside the iOS app's own container and are not visible to the Mac app's sandbox. The user exports each one (Database Details → Export) to somewhere in their own filesystem, then adds it in the native app. Nothing is converted — it is the same `.kdbx` either way.
- **Security-scoped bookmarks do not transfer.** A database the iOS-on-Mac app could reopen silently has to be picked once in the native app; that is inherent to a different app container, not a bug.
- **Cloud and WebDAV databases** are re-added by connecting the account again in the native app. The remote file is untouched, so no export step is involved; only the connection is new.
- **Keychain items are shared**, so a database whose composite key was stored for Touch ID unlock keeps working once the same database is added to the native app — both bundles carry the `com.keevault.sharedkeychain` access group.
- **AutoFill has to be re-enabled once**, in System Settings → General → AutoFill & Passwords, pointing at the native app. Until the iOS app is gone, both claim the same extension identifier and the native one is shadowed (above).
- **Nothing is deleted by the transition.** The iOS app's container survives until the user removes the app themselves, so the export step can be repeated if something was missed. Say so explicitly wherever this is written up for users — the failure mode people fear here is losing a vault.

Two release tasks fall out of this: the direct-download and Mac listing pages on keeforge.com need this as user-facing copy, and the App Store Connect change (unchecking Mac availability for the iOS app) should land only after the native app is live, so nobody is left without either.

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

## What Mac Work Has To Test

The rule of thumb from `../AGENTS.md` ("macOS Test Strategy") in the form a change author needs: find the row your change is in, and write what it names before you call the change done. Mac XCUITest is the last resort on every row — it needs an unlocked login session, grabs real screen and input focus, and serializes against every other Xcode run on the machine.

| What you changed | What must exist when you are done |
| --- | --- |
| Behavior in a view model, service, or model reachable on macOS | A `KeeForgeTests/` test. It compiles into `KeeForgeMacTests` for free, so this is the cheapest coverage there is and the default answer. |
| Behavior that only exists on macOS (`#if os(macOS)` in a view model or service) | A `#if os(macOS)` test in `KeeForgeTests/`, guarded the way `MacLockMonitorTests` and `CloudProviderDesktopAuthTests` are. It runs in `KeeForgeMacTests` only, and CI runs it on every PR. |
| A Mac-only interaction with no view-model seam (keyboard routing, first-responder handling, window lifecycle) | First try to give it a seam and test the seam. If it genuinely cannot have one, add the smallest possible case to `../KeeForgeMacUITests/MacSmokeUITests.swift` — and say in the test why a unit test could not reach it, the way the unlock field's absence of unit coverage is recorded in `../KeeForgeTests/README.md`. |
| Layout or visual polish (sizing, spacing, hover, empty states) | No new assertions. Re-run `MacScreenshotAuditUITests` and look at the captures; add a screen to that walk if the change introduced one. |
| An accessibility identifier | Update every suite that names it, in the same change — `../KeeForgeUITests/` and `../KeeForgeMacUITests/` share identifiers by convention. |
| User-facing text | Translations for all five shipped locales plus a `LocalizationTests` run; the Mac targets use the same four catalogs the iOS ones do. |
| Parser, writer, protected fields, unknown XML, or any save path | `../KeeForgeTests/KDBXCompatibilityTests.swift`, plus the compatibility gate per platform: `KDBX_COMPAT_SCHEME=KeeForgeMac ci_scripts/run_kdbx_compatibility_gate.sh`. |
| Entitlements, the App Group container, the AutoFill extension boundary, or Sparkle | `docs/macos-security-notes.md` refreshed against what actually shipped, and `AppGroupGuardrailTests` re-run if the container's write surface moved. |

Two standing constraints behind the table:

- **`KeeForgeMacUITests` never runs in CI.** It needs an unlocked, active login session no runner has, so it is a local pre-release step only (`.github/AGENTS.md`). A behavior whose only coverage is a Mac UI test is, for CI purposes, uncovered — which is the whole reason the first column pushes so hard toward view models.
- **`KeeForgeMacTests` has no folder.** It compiles `../KeeForgeTests/`, so every test you add there costs both platforms' runtime. Keep macOS-only cases behind `#if os(macOS)` rather than branching inside a shared test.

## Distribution Channels

One target, two channels, chosen when the project is generated rather than when it is built:

- `xcodegen generate` — **Mac App Store**: no Sparkle in the binary, StoreKit tip jar, universal purchase with iOS. The default, so every ordinary workflow and every CI job builds this.
- `xcodegen generate --spec project-direct.yml` — **Developer ID direct download**: links Sparkle, compiles `KEEFORGE_DIRECT_DOWNLOAD`, shows GitHub Sponsors instead of the tip jar, never calls StoreKit. `ci_scripts/build_mac_direct.sh` drives it and restores the App Store spec on exit.

Two specs rather than two targets: both channels ship an app named `KeeForge.app` (the executable name is inside the signature and cannot be renamed afterwards), and two targets producing the same product path is a hard Xcode error. Separate specs also make the channels mutually exclusive by construction — an App Store build must never contain an updater.

Read the channel at runtime through `DistributionChannel` only. `SUFeedURL` / `SUPublicEDKey` in `Info.plist` come from the `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` build settings and are empty in the App Store build, which ignores them.
