# Slice 01: macOS Target Scaffolding + Compile + Unit Tests Green

> Parent: [`epic.md`](./epic.md) · Depends on: —

## Goal

`KeeForgeMac.app` builds with Hardened Runtime under App Sandbox, launches, and can open/browse/edit/save a local KDBX; the full unit-test suite runs on macOS with a short, documented quarantine list.

## Scope

**In:**
- New `KeeForgeMac` (application) and `KeeForgeMacTests` (unit-test) targets, scheme, entitlements, Info.plist.
- The mechanical `#if os()` seam pass across ~25 files plus one shared `PlatformCompat.swift` shim.
- The load-bearing sandbox/keychain correctness changes (security-scoped bookmarks, data-protection keychain, non-Touch-ID degrade).
- Manual-dispatch macOS CI job.

**Out:** anything a Mac user would call UX — menu commands, Settings scene, lock lifecycle, view polish (slice 02); working cloud OAuth (slice 03 — Dropbox/OneDrive stubs may throw on macOS here); AutoFill (slices 04/05); screen privacy beyond a compile stub (slice 06).

## Affected areas

- New: `KeeForgeMac/Info.plist`, `KeeForgeMac/KeeForgeMac.entitlements`, `KeeForge/Extensions/PlatformCompat.swift`.
- Modified (`project.yml`): two new targets + `KeeForgeMac` scheme (mirror the existing scheme incl. the `prepare_build_config.sh` preAction); `deploymentTarget` gains `macOS: "14.0"`.
- Modified (load-bearing):
  - `KeeForge/Services/Persistence/SecurityScopedBookmarkManager.swift` — bookmark creation AND resolution must use `.withSecurityScope` on macOS (currently `options: []` in both directions; without this, file access silently fails after relaunch under sandbox).
  - `KeeForge/Services/Security/KeychainService.swift`, `KeeForge/Services/Cloud/CloudTokenStore.swift` — add `kSecUseDataProtectionKeychain: true` to every SecItem dictionary (the only two SecItem files; harmless on iOS, required on macOS to avoid the legacy file keychain).
  - `KeeForge/ViewModels/DatabaseViewModel.swift` — `persistCompositeKeyForBiometricUnlock` silently skips storage when `.biometryCurrentSet` is unsatisfiable (no enrolled biometrics — the common Mac desktop case); no retry loops, password unlock remains primary.
- Modified (mechanical `#if os()` seams):
  - `KeeForgeApp.swift` — force regular layout on macOS (`\.horizontalSizeClass` doesn't exist there); `NSApplication` key-window branch for the `ASPresentationAnchor` helper; same pattern in `RegularDatabaseWorkspaceView.swift` and `CloudFileBrowserView.swift` (×2).
  - `ClipboardService.swift` (NSPasteboard basic set/clear — full auto-clear behavior in slice 02), `HapticService.swift` (no-op), `FaviconService.swift`/`FaviconView.swift` (`PlatformImage`), `DatabaseOpenFailure.swift` (`ProcessInfo` diagnostics), `ScreenProtectionService.swift` (`#if os(iOS)` + empty mac stub), `EntryDetailView.swift` (interim `.textSelection(.enabled)` for notes on macOS), `AttachmentQuickLookPreview.swift` (`#if os(iOS)`; mac preview in slice 06), `DropboxCloudProvider.swift`/`OneDriveCloudProvider.swift` (`#if os(iOS)` around auth-presentation; throwing mac stub until slice 03).
  - `PlatformCompat.swift` covers the view long tail: semantic colors, no-op `navigationBarTitleDisplayMode` compat (12 files), toolbar-placement helpers for `.topBarLeading`/`.topBarTrailing` (4 files), `.insetGrouped` fallback (3 sites).
  - `LocalDatabaseSaver.swift`/`DatabaseCreationService.swift`: **no change** — the `NSClassFromString("UIApplication")` reflection already no-ops on macOS (verified).
- Modified: `.github/workflows/ci.yml` — manual-dispatch `macos-build-and-test` job (`xcodegen generate` → `xcodebuild test -scheme KeeForgeMac -destination 'platform=macOS'`).

**First-hour risk item:** verify macOS provisioning accepts App Group `group.com.keevault.shared` and the shared keychain access group on this App ID before writing any further code. This is the classic silent-failure item; if it fails, everything downstream re-plans.

## KeeForge bits

- **Targets:**
  - `PlatformCompat.swift`: KeeForge, KeeForgeAutoFill, KeeForgeMac (and KeeForgeMacAutoFill when slice 05 creates it).
  - All modified shared Services/Views files keep their existing memberships and gain KeeForgeMac.
  - `KeeForgeMac/Info.plist` + entitlements: KeeForgeMac only.
- **project.yml:**
  - Add `KeeForgeMac` target: `type: application`, `platform: macOS`, same source lists as `KeeForge` (minus iOS-only resources like `LaunchScreen.storyboard` if present), `ENABLE_HARDENED_RUNTIME: YES`, `PRODUCT_BUNDLE_IDENTIFIER: com.keevault.app`, entitlements `KeeForgeMac/KeeForgeMac.entitlements` (app-sandbox, files.user-selected.read-write, network.client, bookmarks.app-scope, App Group, keychain-access-groups; zero `com.apple.security.cs.*` exceptions).
  - Add `KeeForgeMacTests`: `bundle.unit-test`, `platform: macOS`, sources `KeeForgeTests/` + the same fixture resource list as `KeeForgeTests`, TEST_HOST → KeeForgeMac.app.
  - Add `KeeForgeMac` scheme with the `prepare_build_config.sh` preAction.
  - Add `deploymentTarget.macOS: "14.0"` under `options`.
  - Run `xcodegen generate`.
- **Accessibility identifiers:** N/A — no view behavior changes in this slice; all existing identifiers preserved by construction (shared sources).

## Testing

- **Unit:** the entire existing suite recompiled for macOS is this slice's test suite. Run: `xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac -destination 'platform=macOS' -only-testing:KeeForgeMacTests -quiet`.
  - Target ≥95% pass; every skipped/quarantined test gets an inline `#if os()` comment naming the reason (keychain entitlement on unsigned CI, iOS path-layout assumption, …) and a list in this slice's PR description.
  - New: `SecurityScopedBookmarkManagerTests` additions — bookmark created on macOS resolves with security scope and `startAccessingSecurityScopedResource()` succeeds; iOS behavior unchanged.
  - New: App Group guardrail test — assert `SharedVaultStore` writes only `.kdbx` payloads, bookmark blobs, and filename metadata under the group container (guardrail note also added to `KeeForge/Services/Persistence/README.md`; the container is user-world-readable on macOS 14).
  - Keychain: `KeychainMigrationTests`/`CloudTokenStoreTests` must pass on macOS with `kSecUseDataProtectionKeychain` — these prove the data-protection keychain switch.
- **Integration / UI:** N/A — deferred to slice 02's smoke suite; this slice's exit is manual.
- **Manual:**
  - Launch KeeForgeMac, open `TestFixtures/test.kdbx` via the open panel, unlock with `testpassword123`, browse groups, edit an entry, save.
  - Quit, relaunch, reopen from the database list — proves `.withSecurityScope` bookmark resolution across relaunch (the only way to prove it).
  - Confirm the app runs sandboxed (`codesign -d --entitlements -` shows app-sandbox + hardened runtime, no `get-task-allow`).
- **Edge cases that apply:** locked DB (lock/unlock cycle works even without the slice-02 triggers), no-biometrics Mac (password unlock only; no keychain error surfaced), offline (local DB fully functional), stale bookmark (file moved between launches → existing stale-bookmark recovery path).

## Exit criteria

- [ ] Both schemes build; `KeeForgeTests` (iOS) still fully green.
- [ ] ≥95% of unit tests pass on macOS; quarantine list documented.
- [ ] Manual checks done, incl. the relaunch bookmark check.
- [ ] No force unwraps; secrets via `EncryptedValue`; heavy work off main.
- [ ] `xcodegen generate` run; folder READMEs updated for new files (`KeeForge/Extensions/`, `KeeForge/Services/Persistence/`).
- [ ] CHANGELOG entry under `## Unreleased`.

## CHANGELOG entry

`- Add experimental macOS build target (not yet released): full KDBX core, local vaults, and unit-test suite running natively on Mac.`
