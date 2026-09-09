# KeeForgeMac Target

Configuration folder for the native macOS app target — only `Info.plist`, `KeeForgeMac.entitlements` (Mac App Store) and `KeeForgeMacDirect.entitlements` (direct download); no Mac-only sources.

## Status

The Mac app has **not shipped yet**. `CHANGELOG.md` under `## macOS App` is the single
place where pre-release work is tracked — the remaining checklist, what has been
observed, and what is still open all live there. Do not restate any of it here, and log
macOS work there rather than under `## Unreleased` (iOS release notes).

This file is reference material for working in the target: constraints, platform limits,
gotchas, and what a given change has to test.

## AutoFill Provider Missing From System Settings

**Fixed.** The cause was a missing entitlement on the *containing app*, not on the extension.

`AutoFillExtension/AutoFillExtensionMac.entitlements` carried `com.apple.developer.authentication-services.autofill-credential-provider`; `KeeForgeMac/KeeForgeMac.entitlements` did not. The iOS app target (`KeeForge/KeeForge.entitlements`) always had it, so this was macOS-only drift. macOS lists a credential provider in System Settings → General → AutoFill & Passwords only when the containing app claims that entitlement too. With it on the extension alone, `pluginkit` registers the appex happily and the pane never shows it — exactly the "correct registration and entitlements, still absent" symptom.

Why it went unfound for so long: every check that was run looked at the extension, where the entitlement was present and correct. Nothing compared the Mac app target against its iOS counterpart.

The App ID `com.keevault.app` already carries the AutoFill Credential Provider capability — the iOS app uses it — and the Developer ID profile already authorizes the entitlement, so the fix was the entitlements file alone: no portal change, no hand-made profile, no rebuild of the extension.

Verifying on a Mac:

```bash
codesign -d --entitlements - --xml /Applications/KeeForge.app | plutil -p - | grep autofill
pluginkit -mAvvv -p com.apple.authentication-services-credential-provider-ui
```

The first must print the entitlement. The second should list exactly one provider, at the `/Applications` path. More than one registration of `com.keevault.app.autofill` means a stale build is competing for the identifier; macOS resolves an identifier to a single winner, so clear the strays before trusting what the pane shows. DerivedData `Debug/KeeForge.app` products and old `/Applications` copies are the usual sources, and `mdfind "kMDItemCFBundleIdentifier == 'com.keevault.app'"` lists the candidates.

## AutoFill Suggestions Come From One Database At A Time

**Platform limit, not a bug to fix.** macOS reports `ASCredentialIdentityStoreState.supportsIncrementalUpdates == false` (verified against a real enabled provider on macOS 26.5, `isEnabled == true`). Apple's contract for that mode is explicit: `saveCredentialIdentities` means "pass *all* credential identities", and `removeCredentialIdentities` is documented as usable only when incremental updates are supported. Store enumeration is no better — `credentialIdentities(forService: nil)` comes back empty, or holding private `SFPasswordCredentialIdentity` objects that do not respond to `recordIdentifier`.

The iOS aggregation design depends on both: it enumerates the store, attributes each identity to a database through the `v2:<database>:<entry>` record identifier, then removes that database's own identities and saves the fresh set. On macOS neither half works, so what shipped was non-deterministic — Safari suggested from whichever database was unlocked last — and every targeted removal was a silent no-op, leaving a disabled or deleted database's suggestions in the store indefinitely.

`CredentialIdentityStoreManager` now reads `CredentialIdentityStoreCapabilities` before every write. Without incremental updates:

- a refresh is one `replaceCredentialIdentities` (or `removeAllCredentialIdentities` when the database has no eligible entries), so the most recently unlocked AutoFill-enabled database owns the store;
- a targeted removal clears the store instead, which is the only reduction available and is self-healing — suggestions return on the next unlock.

Record identifiers are still tagged and still resolve, so tapping a suggestion unlocks its owning database. The other databases stay reachable through the extension's database switcher and `defaultAutoFillDatabase`. The gate is the runtime flag rather than `#if os(macOS)`, so aggregation starts working on its own if a macOS release ever reports incremental support.

Diagnosing this on a Mac: launch with `-autofill-store-inspector` (DEBUG only) and read the Store State section, which reports **Incremental updates** alongside Enabled and the identity count.

## Moving Off The iOS App On A Mac

Whether to withdraw the iOS app's Mac availability is a product decision tracked in
`CHANGELOG.md`, not something this file settles. What belongs here are the container
constraints that hold either way, because they are properties of the platform rather
than of the plan:

- **Local databases** live inside the iOS app's own container and are not visible to the
  Mac app's sandbox. The user exports each one (Database Details → Export) somewhere in
  their own filesystem, then adds it in the native app. Nothing is converted — it is the
  same `.kdbx` either way.
- **Security-scoped bookmarks do not transfer.** A database the iOS-on-Mac app could
  reopen silently has to be picked once in the native app. That is inherent to a
  different app container, not a bug.
- **Cloud and WebDAV databases** are re-added by connecting the account again. The remote
  file is untouched, so no export step is involved; only the connection is new.
- **Keychain sharing is expected but unproven in production.** Both bundles carry the
  `com.keevault.sharedkeychain` access group, so a stored composite key may remain usable
  once the same database is added natively — verify it without exposing key material
  before relying on it.
- **AutoFill has to be re-enabled once**, in System Settings → General → AutoFill &
  Passwords. Both bundles claim the same extension identifier and macOS resolves an
  identifier to a single winner, so which one the pane offers with both installed is
  untested. If the native provider does not appear, check for a competing registration
  with the `pluginkit` command above.
- **Never promise that the legacy container survives a native install.** The iOS and
  native apps (and their extensions) reuse bundle identities, so installing one can
  replace or rebind the other's app, container, or provider. Preserve the legacy source
  with a backup, snapshot, or other recoverable harness first, and only promise
  preservation that a completed production probe has actually established.

These are design rules, not production-observed compatibility. The matrix that would turn
them into observed outcomes is in `CHANGELOG.md`; until it is populated, treat every row
as unknown.

## Target Map

- `KeeForgeMac` (app target in `project.yml`): requires macOS 15 and compiles the shared `KeeForge/` tree (minus `LaunchScreen.storyboard`) plus selected `AutoFillExtension/` shells (sharing rules: `KeeForge/README.md`). `MARKETING_VERSION` tracks iOS in lockstep — all four product targets carry the same version and build number, and one release bump covers them together. `PRODUCT_NAME` is `KeeForge`, so the bundle on disk is `KeeForge.app` (it was `KeeForgeMac.app` while the target was internal-only).
- `KeeForgeMacAutoFill` (extension): uses `AutoFillExtension/InfoMac.plist` and `AutoFillExtension/AutoFillExtensionMac.entitlements`; its shared-source list must stay literally identical to the iOS `KeeForgeAutoFill` allow-list (marked invariant in `project.yml`).
- `KeeForgeMacTests`: **no folder of its own** — compiles the shared `KeeForgeTests/` sources, hosted in `KeeForge.app` (`TEST_HOST`/`BUNDLE_LOADER`).
- `KeeForgeMacUITests`: has its own folder and README (`KeeForgeMacUITests/`).

## Entitlements Gotchas

- App Sandbox + Hardened Runtime, user-selected read-write files, network client, app-scoped security bookmarks, App Group `group.com.keevault.shared`.
- `keychain-access-groups`: the app and the extension both list exactly one group, `com.keevault.sharedkeychain`. Ordering matters the moment a second one is added — items stored without an explicit `kSecAttrAccessGroup` land in the **first** listed group, so the shared group must stay first (see comments in both entitlements files). MSAL's macOS token cache group (`com.microsoft.identity.universalstorage`) is deliberately absent: macOS ships WebDAV only, so nothing authenticates through MSAL. Re-enabling OneDrive means adding it back *and* regenerating the Developer ID profiles, which embed the entitlements.

## Info.plist Sync

Keep `Info.plist` in sync with `KeeForge/Info.plist` and `AutoFillExtension/InfoMac.plist`, minus the cloud OAuth surface: the Mac app builds neither cloud SDK, so it deliberately declares **no** `db-*`/`msauth.*` URL scheme and none of the `DropboxAppKey`/`OneDriveClientID`/`OneDriveRedirectURI` keys the iOS plist carries (`URLSchemeFormatTests` pins their absence). What must stay in sync: the `otpauth` scheme that routes incoming verification-code links into `TOTPEnrollmentDestinationView`, the ATS arbitrary-loads-plus-first-party-exceptions setup, and kdbx document/UTType declarations. `DropboxAppKey`, `OneDriveClientID`, and `OneDriveRedirectURI` are explicitly excluded from the Mac plist and runtime/configuration surface.

## Security Posture

Per-platform security deltas vs iOS: `docs/macos-security-notes.md` — a living doc; update it when Mac-relevant security behavior changes.

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
| Behavior that only exists on macOS (`#if os(macOS)` in a view model or service) | A `#if os(macOS)` test in `KeeForgeTests/`, guarded the way `MacLockMonitorTests` and `CloudProviderDesktopAuthTests` are. It runs in `KeeForgeMacTests` only, and CI runs it on every PR. |
| A Mac-only interaction with no view-model seam (keyboard routing, first-responder handling, window lifecycle) | First try to give it a seam and test the seam. If it genuinely cannot have one, add the smallest possible case to `../KeeForgeMacUITests/MacSmokeUITests.swift` — and say in the test why a unit test could not reach it, the way the unlock field's absence of unit coverage is recorded in `../KeeForgeTests/AGENTS.md`. |
| Layout or visual polish (sizing, spacing, hover, empty states) | No new assertions. Re-run `MacScreenshotAuditUITests` and look at the captures; add a screen to that walk if the change introduced one. |
| A SwiftUI view the macOS AutoFill shell hosts (`AutoFillExtension/`) | A manual pass in a real AutoFill panel — nothing automated reaches these views. Check first that every action is drawn *inside* the view: `.toolbar` and `.searchable` go to the window's `NSToolbar` on macOS, and the system credential-provider window has none, so a toolbar-only Cancel compiles, tests green, and ships a panel with no exit. See `../AutoFillExtension/AGENTS.md`. |
| An accessibility identifier | Update every suite that names it, in the same change — `../KeeForgeUITests/` and `../KeeForgeMacUITests/` share identifiers by convention. |
| User-facing text | Translations for all five shipped locales plus a `LocalizationTests` run; the Mac targets use the same four catalogs the iOS ones do. |
| Parser, writer, protected fields, unknown XML, or any save path | `../KeeForgeTests/KDBXCompatibilityTests.swift`, plus the compatibility gate per platform: `KDBX_COMPAT_SCHEME=KeeForgeMac ci_scripts/run_kdbx_compatibility_gate.sh`. |
| Anything writing to the system credential identity store | A `KeeForgeTests/CredentialIdentityStoreManagerTests.swift` case against `FakeCredentialIdentityStore` with `supportsIncrementalUpdatesValue = false`, alongside the incremental one. macOS takes that branch for every write. |
| Entitlements, the App Group container, the AutoFill extension boundary, or Sparkle | `docs/macos-security-notes.md` refreshed against what actually shipped, and `AppGroupGuardrailTests` re-run if the container's write surface moved. |

Two standing constraints behind the table:

- **`KeeForgeMacUITests` never runs in CI.** It needs an unlocked, active login session no runner has, so it is a local pre-release step only (`.github/AGENTS.md`). A behavior whose only coverage is a Mac UI test is, for CI purposes, uncovered — which is the whole reason the first column pushes so hard toward view models.
- **`KeeForgeMacTests` has no folder.** It compiles `../KeeForgeTests/`, so every test you add there costs both platforms' runtime. Keep macOS-only cases behind `#if os(macOS)` rather than branching inside a shared test.

## Distribution Channels

One target, two channels, chosen when the project is generated rather than when it is built:

- `xcodegen generate` — **Mac App Store**: no Sparkle in the binary and StoreKit tip jar. Universal purchase with iOS is intended once the one-time ASC setup is completed; it is not current ASC state. This is the default, so every ordinary workflow and every CI job builds this.
- `xcodegen generate --spec project-direct.yml` — **Developer ID direct download**: links Sparkle, compiles `KEEFORGE_DIRECT_DOWNLOAD`, shows GitHub Sponsors instead of the tip jar, never calls StoreKit. It is also the only spec that selects `KeeForgeMacDirect.entitlements` and sets `SUEnableInstallerLauncherService`: a sandboxed app cannot submit Sparkle's installer job itself, and without the `-spks`/`-spki` mach-lookup exceptions an update downloads and verifies and then hangs forever at the progress window. Those two entitlement files must stay identical apart from that one key. `ci_scripts/build_mac_direct.sh` drives it and restores the App Store spec on exit.

Two specs rather than two targets: both channels ship an app named `KeeForge.app` (the executable name is inside the signature and cannot be renamed afterwards), and two targets producing the same product path is a hard Xcode error. Separate specs also make the channels mutually exclusive by construction — an App Store build must never contain an updater.

Read the channel at runtime through `DistributionChannel` only. `SUFeedURL` / `SUPublicEDKey` in `Info.plist` come from the `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` build settings and are empty in the App Store build, which ignores them.
