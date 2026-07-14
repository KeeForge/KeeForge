# KeeForge macOS UI Tests

Smoke suite for the native macOS app (target `KeeForgeMacUITests`, scheme `KeeForgeMac`). Methodology and fixture guidance live in `../KeeForgeUITests/README.md` (see its "macOS Smoke Suite" section); this suite reuses the same fixtures and accessibility identifiers.

## Test Classes

- `MacSmokeUITests` — unlock success/failure, group browse, entry detail + copy-username pasteboard round-trip, reveal/copy-password device-owner-auth boundaries, ⌘F search + result count, edit + save, ⌘L lock, ⌘N new entry, ⌘, settings window, Escape on the unlock screen.
- `MacDatabaseListUITests` — two seeded databases, right-click Remove flow.
- `MacWebDAVSmokeUITests` — seeded WebDAV mock round-trip via `UITestWebDAVCloudProvider` (`UI_TEST_WEBDAV_PAYLOAD_JSON`), unlock + ⌘L.

## Running

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:KeeForgeMacUITests/MacSmokeUITests
```

Requirements and gotchas:

- The login session must be unlocked and active; a locked screen fails every launch with "Failed to activate application (Running Background)".
- `MacUITestCase` passes `-ApplePersistenceIgnoreState YES`; without it macOS state restoration can restore a zero-window session.
- Prefer accessibility identifiers, `typeKey` shortcuts, `click()`/`rightClick()`; there is no swipe/scroll gesture support like iOS.
- Reveal/copy-password tests assert up to the auth-prompt boundary; app termination in teardown dismisses the system prompt.
