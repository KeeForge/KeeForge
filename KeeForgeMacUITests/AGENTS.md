# KeeForge macOS UI Tests

Smoke suite for the native macOS app (target `KeeForgeMacUITests`, scheme `KeeForgeMac`). Methodology and fixture guidance live in `../KeeForgeUITests/README.md`; this suite reuses the same fixtures and accessibility identifiers — preserve them in both places. `MacUITestCase` mirrors the iOS target's fixture-injection launch environment but uses clicks, `typeKey` keyboard shortcuts, and right-click context menus instead of taps/swipes.

## Test Classes

- `MacSmokeUITests` — unlock success/failure, group browse, entry detail + copy-username pasteboard round-trip, ⌘F search + result count, edit + save, ⌘L lock, ⌘N new entry, ⌘, settings window, keyboard focus landing in the unlock password field and Escape from it (neither clicks the field first, which would hide a focus failure), and arrow-key movement in the sidebar and entries columns.
- `MacListKeyboardNavigationUITests` — arrow-key movement in the two content-column lists that are not a group's entries: search results and the tag browser. Both render `MacEntriesList` rather than the shared iOS `EntryListView`, whose button rows swallow the click a native `List(selection:)` needs; these tests are what catch a regression back to it. They assert only that a keystroke moves the selection, never which entry it lands on, so they do not re-encode the fixture's sort order. Uses `kitchen-sink.kdbx` — the only bundled database with entry tags, so the only one whose sidebar has a Tags section.
- `MacSearchResultsDeleteUITests` — right-click Delete in the same two `MacEntriesList` surfaces, plus the cancel path. Both render inline in the workspace content column, which already hosts a `PendingDeletion`, so the list has to raise its confirmation there rather than add a second `.alert(item:)` — two siblings on one presentation context collide and SwiftUI silently drops one (the iOS form of this was #118). Each case asserts the confirmation actually appears, because the failure mode is a silent no-op rather than an error. Uses `kitchen-sink.kdbx` for the tag section, like the class above. **Match a context-menu item as an enabled, hittable `menuItems` element, never `firstMatch` on title**: the menu bar carries its own disabled Edit ▸ Delete and ⌘⌫ Delete, and `firstMatch` picks one of those, clicks nothing, and leaves the context menu open with the window modal — which reads exactly like the bug under test.
- `MacPasswordAuthBoundaryUITests` — reveal/copy-password device-owner-auth boundaries, launched with `UI_TEST_DEVICE_OWNER_AUTH_PENDING=1` (see below).
- `MacDatabaseListUITests` — two seeded databases, right-click Remove flow.
- `MacWebDAVSmokeUITests` — seeded WebDAV mock round-trip via `UITestWebDAVCloudProvider` (`UI_TEST_WEBDAV_PAYLOAD_JSON`), unlock + ⌘L.
- `MacWhatsNewUITests` — current Mac-filtered feature content and dismissal, forced through `UI_TEST_SHOW_WHATS_NEW=1` while the sheet stays suppressed in all unrelated UI tests.
- `MacScreenshotAuditUITests` — walks the primary screens and attaches `.keepAlways` per-window screenshots for visual UX auditing (app windows only, never the whole desktop). Covers the database list, unlock, vault root, a selected group, entry detail, ⌘F search, every Settings tab, the entry-editor sheet, and the three-column layout at the 900pt minimum window size. It injects the standard `test` fixture as `Personal.kdbx`, so listing captures show a presentable vault name. It searches for `Email`, and sets `UI_TEST_HIDE_SEARCH_RESULTS_COUNT=1` so the `results:N` test overlay stays out of the captures (other suites still read `search.results.count`). Skips unless launched with `TEST_RUNNER_SCREENSHOT_AUDIT=1`. Captures are forced light through the app's appearance preference whatever the host uses; `TEST_RUNNER_SCREENSHOT_AUDIT_DARK=1` switches them to dark; export with `xcrun xcresulttool export attachments`:

  ```bash
  TEST_RUNNER_SCREENSHOT_AUDIT=1 xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:KeeForgeMacUITests/MacScreenshotAuditUITests
  ```

  Two things this harness has to do that are not obvious:

  - **It launches with `-KeeForge.blockScreenCapture NO`.** The app blocks screen capture by default, which sets `sharingType = .none` on every window and excludes them from the capture composite — ScreenCaptureKit then returns a blank image, and a screen-region capture returns whatever sits *behind* the app. A screenshot harness has to opt out of the protection it is photographing.
  - **It needs Screen Recording permission for `KeeForgeMacUITests-Runner`**, because captures come from each window's own content via ScreenCaptureKit rather than from `XCUIElement.screenshot()` (which region-captures the screen). Without the permission every capture is recorded as a skip in the `00-skipped-captures` attachment rather than attaching whatever was underneath. Grant it once under System Settings → Privacy & Security → Screen & System Audio Recording.

  Skipped captures are always reported — in that attachment and in the test log — so a short export is visibly a harness problem rather than a screen that does not exist.

  Both variables must be real environment variables on the `xcodebuild` process itself (Xcode strips the `TEST_RUNNER_` prefix and forwards them into the test runner's environment) — verified empirically on the macOS destination, passing one as a trailing bare `KEY=value` argument makes it a build-setting override that never reaches the test runner, and the class silently skips as if unset. Same footnote as the iOS `AppStoreScreenshots` gate in `../KeeForgeUITests/README.md`.

## Running

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:KeeForgeMacUITests/MacSmokeUITests
```

Requirements and gotchas:

- macOS UI tests require an unlocked, active login session; they fail with "Failed to activate application (Running Background)" when the screen is locked. They also need Automation Mode: if `automationmodetool` (no arguments, read-only) reports that enabling it requires user authentication, the runner prompts and fails with "Timed out while enabling automation mode" after running zero tests unless someone is present to authenticate.
- `MacUITestCase` launches with `-ApplePersistenceIgnoreState YES`; without it, macOS state restoration can restore a zero-window session and no main window ever appears.
- **The reveal/copy-password gate is off under `-ui-testing`.** XCUITest cannot dismiss the system device-owner prompt, so `BiometricService.canAuthenticateDeviceOwner` reports false for every UI-test launch and the app reveals and copies straight away — a boundary test launched without the stub sees that as a leak and fails. `MacPasswordAuthBoundaryUITests` therefore launches with `UI_TEST_DEVICE_OWNER_AUTH_PENDING=1`, which re-arms the gate with an authentication that never completes: the state a user is in while the prompt is on screen, with no dialog for the runner to fight.
- **The Settings window reopens on whichever tab was used last.** SwiftUI's `Settings { }` scene persists `com_apple_SwiftUI_Settings_selectedTabIndex` in the app's own preferences, which a UI-test launch does not reset, so a Mac where anyone has opened Settings on another tab lands there. Select the tab you need with `MacUITestCase.selectSettingsTab(named:)` instead of assuming Security.
- **Never query vault rows as `app.buttons`, and never match their text on `label` alone.** The vault columns are native `List(selection:)`, so `group.navlink` / `entry.navlink` surface as `Outline`/`Cell`/`StaticText` on macOS even though the same identifiers are buttons on iOS — and most SwiftUI `Text` reports through the AppKit `value` attribute with an empty `label` (a row with a disclosure triangle is the exception and uses `label`). Go through `MacUITestCase.openGroup` / `openEntry` / `rowQuery(identifier:)` / `displayText(of:)` / `waitForDisplayText(_:identifier:)`, which handle both attributes and filter for hittability. `waitForDisplayText` re-queries every pass rather than holding one element, because reading a property off an element a rebuilding SwiftUI view has just replaced fails the test outright.
- Closing the last app window locks the vault (`MacLockMonitor.Trigger.lastWindowClosed`). A test that presses ⌘W must be sure another window is still open — closing the Settings window while the main window stands is fine.
