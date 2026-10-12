# KeeForgeMacUITests

**Scope:** XCUITest smoke suite for the native macOS app (scheme `KeeForgeMac`). It is a thin layer by design; see "macOS Test Strategy" in `../AGENTS.md`. The fix workflow, launch environment, and fixtures are shared with `../KeeForgeUITests/AGENTS.md`.

## Running

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:KeeForgeMacUITests/MacSmokeUITests
```

- The suite never runs in CI. It drives real windows and takes screen and keyboard focus, so it needs an unlocked, active login session; with the screen locked it fails with "Failed to activate application (Running Background)".
- It needs Automation Mode. If `automationmodetool` (no arguments, read-only) says enabling it requires authentication, the runner prompts and, unattended, fails with "Timed out while enabling automation mode" after running zero tests. Zero tests run is a failure, not a pass.
- `MacSmokeUITests` is the required local release smoke (`prepare-release` skill). Run one class per invocation.
- `MacScreenshotAuditUITests` skips unless `TEST_RUNNER_SCREENSHOT_AUDIT=1` is set; `TEST_RUNNER_SCREENSHOT_AUDIT_DARK=1` switches its captures to dark. Both must be real environment variables on the `xcodebuild` process: a trailing `KEY=value` argument is a build-setting override that never reaches the runner, and the class skips silently.

## Invariants

### Launch

- `-key value` argument pairs can sit on either side of the bare `-ui-testing` flag: argument-domain parsing takes the next token as a flag's value only when it does not start with `-`.
- `-ApplePersistenceIgnoreState YES` stays in the base launch. Without it state restoration can restore a session with no windows and no main window ever appears.
- To capture the app's own windows, launch with `-KeeForge.blockScreenCapture NO`, placed as above. The app excludes its windows from capture by default, so a capture is blank or shows whatever is behind the app.
- The reveal/copy device-owner gate is off under `-ui-testing`, because XCUITest cannot dismiss the system prompt. A boundary test launches with `UI_TEST_DEVICE_OWNER_AUTH_PENDING=1`, which re-arms the gate with an authentication that never completes. Without it, immediate disclosure reads as a leak.

### Queries

- Vault rows are native `List(selection:)` cells, not buttons, although the same `group.navlink` / `entry.navlink` identifiers are buttons on iOS (`../KeeForge/Views/AGENTS.md`). Never query them through `app.buttons`. Use `MacUITestCase.openGroup`, `openEntry`, `clickFirstRow`, or `rowQuery(identifier:)`.
- Most SwiftUI `Text` reports through the AppKit `value` attribute with an empty `label`. Read text with `displayText(of:)` and wait with `waitForDisplayText(_:identifier:)`, which re-queries every pass: reading a property from an element a rebuilding view has replaced fails the test.
- SwiftUI copies row identifiers onto zero-sized wrappers and stale navigation layers. Click only a hittable match with a real height, as the row helpers do.
- Match a context-menu item as an enabled, hittable `menuItems` element, never `firstMatch` on its title. The menu bar holds disabled items with the same titles; `firstMatch` picks one, clicks nothing, and leaves the context menu open and the window modal.
- Toolbar buttons, `lock.button` included, can collapse into the "more toolbar items" overflow, where they are menu items matched by label. Use `clickToolbarButton(identifier:overflowLabel:)`, and detect the unlocked state from vault rows as `waitForVaultToUnlock` does.
- The Settings window reopens on the tab used last, which persists in the app's preferences across launches. Select the tab with `selectSettingsTab(named:)`; the `settings.tab.*` identifiers sit on tab content, not on the switching control.
- Closing the last window locks the vault (`MacLockMonitor.Trigger.lastWindowClosed`). A test pressing Command-W must leave another window open.

### Screenshot audit

- Captures come from each window's own content through ScreenCaptureKit. `XCUIElement.screenshot()` and `XCUIApplication.screenshot()` capture the screen region and return whatever is in front.
- The runner (`KeeForgeMacUITests-Runner`) needs Screen Recording permission, under System Settings > Privacy & Security > Screen & System Audio Recording.
- A capture that cannot be taken is listed in the `00-skipped-captures` attachment instead of attaching the wrong pixels. A short export is a harness problem, not a missing screen.
- Captures are forced light or dark through `-KeeForge.appearanceMode`; the host appearance does not decide. `UI_TEST_HIDE_SEARCH_RESULTS_COUNT=1` keeps the `results:N` test overlay out of them, while other suites still read `search.results.count`.

## Fixtures

The bundle holds only the shared `UITestFixtures` set listed in `../KeeForgeUITests/AGENTS.md`; override `databaseFixtures` to choose. `kitchen-sink.kdbx` is the only one whose sidebar has a Tags section.

## See also

- `../AGENTS.md`: "macOS Test Strategy", including what Mac work has to test
- `../TestFixtures/README.md`: fixture contents and passwords
