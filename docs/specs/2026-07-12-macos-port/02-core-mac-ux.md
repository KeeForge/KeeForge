# Slice 02: Core Mac UX

> Parent: [`epic.md`](./epic.md) · Depends on: 01

## Goal

A daily-drivable, Mac-native app for local and WebDAV vaults: menu bar commands, Settings window, a trustworthy lock lifecycle, per-view polish, and a macOS smoke UI-test suite.

## Scope

**In:**
- Menu bar `.commands` + keyboard shortcuts plumbed to the active database.
- macOS `Settings { }` scene.
- `MacLockMonitor` — the macOS lock-trigger service (this IS the security guarantee on macOS; see epic).
- Reveal/copy authentication fix for non-Touch-ID Macs (with iOS back-port).
- Full `ClipboardService` macOS behavior.
- Per-view polish pass and window behavior.
- `KeeForgeMacUITests` smoke suite (10–15 tests).

**Out:** Dropbox/OneDrive OAuth (slice 03 — WebDAV works in this slice because it's pure URLSession); screen-capture toggle, QuickLook, review prompts (slice 06); App Store/notarization work (slice 07).

## Affected areas

- New: `KeeForge/App/KeeForgeCommands.swift` (CommandGroups: Lock ⌘L, Save ⌘S, Find ⌘F → focus search, New Entry ⌘N, Copy Username ⇧⌘B, Copy Password ⇧⌘C, Close Database; reach the active `DatabaseViewModel` via `.focusedSceneValue`/`FocusedValues` — the one new SwiftUI plumbing pattern in the codebase).
- New: `KeeForge/Services/AppSupport/MacLockMonitor.swift` — observes `NSApplication.didResignActiveNotification`, `DistributedNotificationCenter` `com.apple.screenIsLocked`, screensaver start, `NSWorkspace.willSleepNotification`, and `NSWorkspace.sessionDidResignActiveNotification`; drives the existing `handleSceneDidEnterBackground()` paths and triggers the pending-upload drain on became-active.
- New: `KeeForgeUITests/` mac smoke files (or a `KeeForgeMacUITests/` dir) reusing `KeeForgeUITestCase` helpers and fixtures.
- Modified: `KeeForgeApp.swift` (Settings scene on macOS, `.defaultSize`/min frame, verify kdbx double-click open via existing `CFBundleDocumentTypes` + `handleOpenURL`), `SettingsView.swift` (settings-window layout; also the new lock-policy option), `EntryDetailView.swift` + `BiometricService.swift` (reveal-auth fix), `ClipboardService.swift`, and a timeboxed polish pass over `DatabaseListView`, `GroupListView`, `EntryListView`, `EntryDetailView`, `EntryEditView`, `SearchView`, `UnlockView` (list styles, hover states, double-click to open entry, Escape/Return in unlock, focus rings).
- Modified: `project.yml` — `KeeForgeMacUITests` target; possibly `xcodeVersion` bump 16 → 26 (or a mac asset-catalog icon) so the mac app has an archivable icon.

Behavior decisions this slice must implement, not re-litigate:
- **Default lock policy on macOS:** map the iOS `.immediately` default to **lock on screen-lock/sleep/screensaver/session-resign**, NOT on `didResignActive` (which would lock on every window switch). Expose the stricter lock-on-resign-active as a Settings option. Document the mapping in `SettingsService`.
- **Reveal-auth fix:** gate reveal/copy on `LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)` — login-password/Apple Watch fallback — instead of skipping authentication when `BiometricService.isAvailable` is false (today that means every non-Touch-ID Mac reveals passwords with one unauthenticated click). Back-port the same gate to iOS in this slice.
- **Clipboard ceiling:** changeCount-guarded timer clear (never clobber a later user copy), clear-on-lock, `org.nspasteboard.ConcealedType`; document in Settings copy that Universal Clipboard exclusion does not exist on macOS (no `.localOnly` equivalent — an honest, unavoidable regression vs iOS).

## KeeForge bits

- **Targets:** `KeeForgeCommands.swift` and `MacLockMonitor.swift` → KeeForgeMac only. All modified shared views/services keep existing memberships (KeeForge, KeeForgeAutoFill where already shared) + KeeForgeMac. Smoke tests → KeeForgeMacUITests only.
- **project.yml:** add `KeeForgeMacUITests` (`bundle.ui-testing`, `platform: macOS`, TEST_TARGET_NAME KeeForgeMac, same fixture resources as KeeForgeUITests); wire into the `KeeForgeMac` scheme's test action; icon decision (xcodeVersion bump or asset catalog). Run `xcodegen generate`.
- **Accessibility identifiers:** preserve all existing identifiers (`unlock.password.field`, `unlock.button`, `entry.navlink`, `entry.copy.*`, `sort.menu`, `database-row.*`, …) — the mac smoke suite reuses them. New: identifiers for the Settings window tabs and the new lock-policy picker (e.g., `settings.lock-policy.picker`), and any mac-only toolbar buttons.

## Testing

- **Unit:** `AutoLockTests.swift` — extend for the macOS trigger mapping (screen-lock/sleep/screensaver/session-resign fire lock; resign-active does not under the default policy; does under the strict option). `SettingsServiceTests.swift` — new lock-policy setting round-trips. New `MacLockMonitorTests.swift` — notification-driven lock invocation using injected notification centers (no real screen locking in unit tests).
  Run slice: `-only-testing:KeeForgeMacTests/AutoLockTests -only-testing:KeeForgeMacTests/MacLockMonitorTests -only-testing:KeeForgeMacTests/SettingsServiceTests` (plus the same classes on `KeeForgeTests` for the iOS back-port).
- **Integration / UI:** the new mac smoke suite, 10–15 tests: unlock success/failure, browse groups, search + result count, entry detail + reveal (auth prompt appears), copy password, edit + save, lock via ⌘L, settings window opens via ⌘,, database list add/remove, WebDAV mock round-trip (reuse `UITestWebDAVCloudProvider`).
- **Manual:**
  - Full menu sweep: every command enabled/disabled correctly with no database open, locked, unlocked.
  - Secure keyboard entry active while the unlock `SecureField` is focused (menu-bar "Secure Keyboard Entry" indicator).
  - Lock actually fires on real screen-lock and lid-close; pending-upload drain runs on return.
  - kdbx double-click in Finder opens/focuses the app; window size restoration.
  - Reveal/copy on a Mac **without** Touch ID prompts for the login password (test with biometrics unenrolled).
- **Edge cases that apply:** locked DB (commands disabled, smoke test), lock mid-edit (draft preserved per existing iOS behavior), rapid window switching under strict lock policy, clipboard cleared on lock while timer pending, background→foreground upload drain.

## Exit criteria

- [ ] Unit + smoke tests above pass; iOS suite still green (incl. back-ported reveal-auth tests).
- [ ] Manual checks done.
- [ ] No force unwraps; secrets via `EncryptedValue`; heavy work off main.
- [ ] `xcodegen generate` run; `KeeForge/App/README.md`, `KeeForge/Services/README.md`, `KeeForgeUITests/README.md` updated.
- [ ] CHANGELOG entry under `## Unreleased`.

## CHANGELOG entry

`- macOS: native menu bar commands, Settings window, and automatic locking on screen lock/sleep; password reveal now always requires device-owner authentication (also hardened on iOS).`
