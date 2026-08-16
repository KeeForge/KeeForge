# KeeForge macOS UI Tests

Smoke suite for the native macOS app (target `KeeForgeMacUITests`, scheme `KeeForgeMac`). Methodology and fixture guidance live in `../KeeForgeUITests/README.md`; this suite reuses the same fixtures and accessibility identifiers — preserve them in both places. `MacUITestCase` mirrors the iOS target's fixture-injection launch environment but uses clicks, `typeKey` keyboard shortcuts, and right-click context menus instead of taps/swipes.

## Test Classes

- `MacSmokeUITests` — unlock success/failure, group browse, entry detail + copy-username pasteboard round-trip, reveal/copy-password device-owner-auth boundaries, ⌘F search + result count, edit + save, ⌘L lock, ⌘N new entry, ⌘, settings window, Escape on the unlock screen.
- `MacDatabaseListUITests` — two seeded databases, right-click Remove flow.
- `MacWebDAVSmokeUITests` — seeded WebDAV mock round-trip via `UITestWebDAVCloudProvider` (`UI_TEST_WEBDAV_PAYLOAD_JSON`), unlock + ⌘L.
- `MacWhatsNewUITests` — current Mac-filtered feature content and dismissal, forced through `UI_TEST_SHOW_WHATS_NEW=1` while the sheet stays suppressed in all unrelated UI tests.
- `MacScreenshotAuditUITests` — walks the primary screens and attaches `.keepAlways` per-window screenshots for visual UX auditing (app windows only, never the whole desktop). Skips unless launched with `TEST_RUNNER_SCREENSHOT_AUDIT=1` (`TEST_RUNNER_SCREENSHOT_AUDIT_DARK=1` adds a dark-appearance pass); export with `xcrun xcresulttool export attachments`:

  ```bash
  TEST_RUNNER_SCREENSHOT_AUDIT=1 xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:KeeForgeMacUITests/MacScreenshotAuditUITests
  ```

  Both variables must be real environment variables on the `xcodebuild` process itself (Xcode strips the `TEST_RUNNER_` prefix and forwards them into the test runner's environment) — verified empirically on the macOS destination, passing one as a trailing bare `KEY=value` argument makes it a build-setting override that never reaches the test runner, and the class silently skips as if unset. Same footnote as the iOS `AppStoreScreenshots` gate in `../KeeForgeUITests/README.md`.

## Running

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:KeeForgeMacUITests/MacSmokeUITests
```

Requirements and gotchas:

- macOS UI tests require an unlocked, active login session; they fail with "Failed to activate application (Running Background)" when the screen is locked.
- `MacUITestCase` launches with `-ApplePersistenceIgnoreState YES`; without it, macOS state restoration can restore a zero-window session and no main window ever appears.
- Reveal/copy-password tests assert up to the device-owner auth prompt boundary (the prompt is a system dialog XCUITest cannot automate); terminating the app in teardown dismisses it.
