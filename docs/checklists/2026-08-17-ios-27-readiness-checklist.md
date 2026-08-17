# iOS 27 Readiness Checklist

Written 2026-08-17, against the iOS 27 / Xcode 27 **beta 5** release notes and the repo as of this date. iOS 27 ships ~September 2026. Re-verify anything marked *verify* against the GM release notes; betas change.

## TL;DR

KeeForge is in good shape. Both App Store hard gates for iOS 27 SDK builds (launch screen, scene-based lifecycle) are already satisfied, the codebase uses none of the newly deprecated SwiftUI/UIKit surfaces, and two iOS 27 beta regressions were already found and worked around during beta testing. There is **no forced migration**: the App Store submission floor is the iOS 26 SDK (mandatory since 2026-04-28) and the iOS 27 SDK will likely not be required until ~spring 2027.

The real work is: (1) a first full build/test pass with Xcode 27 once GM lands, (2) watching CI runner images rotate, and (3) closing two pre-existing App Store compliance gaps surfaced while auditing (privacy manifest, `UIRequiredDeviceCapabilities`).

## 1. App Store hard gates for apps built with the iOS 27 SDK

| Requirement | Status |
|---|---|
| Launch screen required (`UILaunchStoryboardName` / `UILaunchScreen` in Info.plist); apps without one are rejected | ✅ Already satisfied — `KeeForge/Info.plist` sets `UILaunchStoryboardName = LaunchScreen` |
| Scene-based lifecycle required; non-scene apps fail to launch | ✅ Already satisfied — pure SwiftUI `App` lifecycle, no `UIApplicationDelegate` anywhere |
| iOS 27 SDK submission mandate | Not yet in force. Floor is iOS 26 SDK (since 2026-04-28); expect the 27 mandate ~spring 2027 per Apple's annual cadence |

## 2. Toolchain and CI

- [ ] **Xcode 27 requires an Apple silicon Mac on macOS Tahoe 26.4+** and ships Swift 6.4. Check every dev machine and the Xcode Cloud macOS version setting before adopting.
- [ ] **GitHub workflows auto-adopt the newest Xcode on the runner** (`ls -d /Applications/Xcode_*.app | sort -V | tail -1` in `ci.yml` and `pr-tests.yml`). When the `macos-15` image adds Xcode 27, CI silently starts building with the iOS 27 SDK — watch the first runs after image rotations. Xcode 27 may only ship on a `macos-26` image; be ready to bump `runs-on`.
- [ ] **`ios18-rc-tests.yml` hard-fails if the runner image drops iOS 18.x simulator runtimes** (deliberate guard, `ios18-rc-tests.yml:76-86`). Image rotations around the Xcode 27 timeframe are the likeliest trigger. If it fires, decide whether to install the runtime in-job or retire the iOS 18 gate.
- [ ] **`iPhone 17 Pro` is hardcoded** as the simulator in `ci.yml`, `pr-tests.yml`, `ci_scripts/run_kdbx_compatibility_gate.sh:22`, `AGENTS.md`, and `KeeForgeUITests/README.md`. Xcode 27 simulators will default to iPhone 18-era devices; update the name (or switch to a device-agnostic destination) when it disappears from the default device set.
- [ ] **Xcode Cloud**: the Xcode version is selected in the App Store Connect UI, not in `ci_scripts/` — bump it there explicitly after local validation. Its test action can only pin "latest runtime", so moving to Xcode 27 moves RC tests to iOS 27 simulators in the same step.
- `project.yml`'s `xcodeVersion: "16.0"` is only XcodeGen's project-object-version pin and needs no change (the repo already builds with Xcode 26.x against it).
- `SWIFT_VERSION: "6.0"` remains a valid language mode under Swift 6.4; no change required.

## 3. First build with Xcode 27 — source compatibility to verify

Run a full build + `KeeForgeTests`/`KeeForgeMacTests` pass with the Xcode 27 GM and check:

- [ ] **`@State` is now a Swift macro** (back-deploys to iOS 17). Our declarations that get assigned in `init` correctly omit declaration-site initial values (e.g. `EntryEditView.swift:6-28`), which is the supported pattern. *Verify* the 18 `_property = State(initialValue:)` init sites (`EntryEditView.swift:45-48`, `AutoFillSearchView.swift:50`, `EntryDetailView.swift:963`, `CloudFileBrowserView.swift`, etc.) still compile — projected-value assignment isn't in Apple's listed exceptions, but it isn't explicitly blessed either.
- [ ] **`Text` + `.textSelection(.enabled)` gains system selection gestures** when built with the 27 SDK. We use it in `EntryDetailView.swift:594,642,851` and `FeedbackComposerView.swift:43` — verify no gesture conflicts in entry rows; apply `.highPriorityGesture()` if custom taps stop winning.
- [ ] **`TabView` crashes if selection is set to a hidden/unavailable tab** (27 SDK enforcement). Our single `TabView` (`SettingsView.swift:51`) has no selection binding — should be unaffected; confirm.
- [ ] **Approachable-concurrency interactions**: Swift 6.4 + strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) may surface new diagnostics; triage rather than suppress.
- Already clean, no action: zero `PreviewProvider` (all `#Preview`), zero `ObservableObject`/`@Published`, zero `NavigationView`, all 41 `onChange(of:)` sites use the two-parameter signature, zero `.roundedBorder`/`.squareBorder` text-field styles, zero MetricKit, zero On-Demand Resources, zero deprecated status-bar accessors.

## 4. AutoFill / password-manager surface

- [ ] **Re-test the credential identity store on iOS 27 GM.** The iOS 27.0-beta enumeration bug (objects not conforming to `ASCredentialIdentity`, trapping the NSArray bridge) is already worked around by `droppingNonConformingIdentities` (`CredentialIdentityStoreManager.swift:111-129`). Keep the workaround — it's harmless when fixed — but confirm the GM behavior and file a Feedback Assistant report if it's still broken.
- [ ] **Run the AutoFill store validation harness** (`docs/specs/2026-07-20-autofill-store-validation-harness/`) on an iOS 27 simulator; note the store historically enumerates empty on some simulator runtimes (18.5, 26.5).
- [ ] **iOS 27 Passwords app "automatic password change"** works agentically through Safari + `/.well-known/change-password` — it's a Safari/iCloud Keychain feature with no third-party credential-provider API in beta 5. Nothing to adopt; keep an eye on whether Apple opens it to credential providers at GM.
- [ ] The extension already declares the full modern capability set (passkeys, one-time codes, passwords, save, generate — `AutoFillExtension/Info.plist:27-41`) and implements the iOS 26.2 save/generate entry points. No new `ASCredentialProviderExtensionCapabilities` keys appear in the 27 beta 5 notes. Re-check the GM AuthenticationServices diffs.

## 5. UI tests on iOS 27

- [ ] The known iOS 27 regression — **accessibility identifiers dropped from buttons inside a `Section` of a SwiftUI `Menu`** — is already handled by the `menuButton(identifier:label:)` helper (`KeeForgeUITests/KeeForgeUITestCase.swift:728-735`; background in `KeeForgeUITests/README.md`). Audit any new menu interactions for identifier-only queries, which hang on iOS 27.
- [ ] Run `KeeForgeUITests` once on an iOS 27 simulator before Xcode Cloud rotates to it, so flakes are found on our schedule rather than during an RC soak.

## 6. Deprecations to clean up opportunistically (not blocking)

- [ ] `UIScreen.main.isCaptured` (`ScreenProtectionService.swift:32`) — `UIScreen.main` is long-deprecated; read `isCaptured` from the window scene's screen instead (the class already tracks `connectedScenes`).
- [ ] The reflection-based `beginBackgroundTask` bridge (`LocalDatabaseSaver.swift:418-445`, `DatabaseCreationService.swift:575-580`) degrades gracefully if the selector vanishes, but verify on iOS 27 that background finish-save protection still engages (log/inspect `AppBackgroundTaskManager.begin` returning `.invalid`).
- [ ] `canOpenURL:` is deprecated in iOS 27 — we don't call it directly, but SwiftyDropbox/MSAL do (we declare `LSApplicationQueriesSchemes`). Expect dependency updates; bump SDKs when they cut iOS 27-compatible releases.

## 7. Pre-existing compliance gaps found during this audit (fix regardless of iOS 27)

- [ ] **No `PrivacyInfo.xcprivacy` exists in any target.** Required-reason APIs are in use (`UserDefaults` across 9 service files, file-timestamp reads in persistence). Privacy manifests have been an App Store requirement since May 2024; add one to the app and both AutoFill extensions declaring the required-reason API categories with standard reason codes (likely `CA92.1` for UserDefaults; audit timestamps/disk-space call sites for `C617.1`/`E174.1`), `NSPrivacyTracking = false`, and no collected data types.
- [ ] **`UIRequiredDeviceCapabilities = ["armv7"]`** (`KeeForge/Info.plist:269-272`) — a 32-bit capability on an arm64-only iOS 18+ app. Replace with `arm64` (safe: every iOS 18 device is arm64).
- ~~`NSAppTransportSecurity` sets `NSAllowsArbitraryLoads = true`~~ — **not a gap on closer inspection.** The Info.plist documents the design in place: user-entered WebDAV hosts can't get per-domain ATS exceptions and frequently lack ATS-approved forward-secrecy ciphers, so arbitrary loads are allowed globally while HTTPS stays enforced in code (HTTP is explicit opt-in) and every first-party domain re-applies full ATS via `NSExceptionDomains`. Leave as is; be ready to justify the flag in App Review notes.

## Suggested sequencing

1. **Now → September**: fix §7 items (shippable immediately, no Xcode 27 needed); keep CI green through runner-image rotations (§2).
2. **Xcode 27 GM (≈September 2026)**: local full build + unit tests (§3), AutoFill retest (§4), UI-test pass on an iOS 27 simulator (§5); then bump Xcode Cloud and let an RC soak on it.
3. **Before ~spring 2027**: be building RCs with the iOS 27 SDK well ahead of the submission mandate; clean up §6 alongside.
