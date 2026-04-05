# KeeForge UI Tests

Detailed guidance for adding, running, and fixing XCUITests in `KeeForgeUITests/`.

Use this document for UI test methodology. Repo-wide build and test policy stays in `AGENTS.md`, and fixture details live in `../TestFixtures/README.md`.

## Current Test Classes

- `DatabaseListUITests` — home-screen database list actions and management
- `UnlockFlowUITests` — basic unlock success/failure coverage
- `BackoffUITests` — failed-unlock backoff behavior
- `LockUnlockUITests` — lock cycle coverage
- `UnlockedDatabaseUITests` — post-unlock navigation, entry detail, search, sort, settings
- `KeyFileUITests` — key file selection and picker flows
- `KeyFileUnlockUITests` — unlocking with a key file
- `AppStoreScreenshots` — screenshot capture flow using demo fixtures

## Running UI Tests

Always run one UI test class at a time:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/UnlockedDatabaseUITests -quiet
```

If one source file contains multiple test classes, run each class separately by class name.

Examples:

```bash
# One standard UI class
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/UnlockFlowUITests -quiet

# Key file-specific class from a shared source file
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/KeyFileUnlockUITests -quiet
```

Do not run the full UI suite unless explicitly asked. It is slow and makes failures harder to isolate.

## UI Test Fix Workflow

Use this loop for every failing UI class:

1. Reproduce with **one UI test class only**
2. Read the failing assertion and the surrounding test helper code
3. If needed, inspect the latest `.xcresult` summary
4. Decide whether the failure is:
   - a real app regression
   - a brittle or outdated test
   - stale project configuration
5. Make the smallest fix that stabilizes the flow
6. Rerun the **same UI test class**
7. Move to the next class only after the current one passes

If Xcode complains about missing or stale test-file references in `.xcodeproj`, regenerate the project:

```bash
xcodegen generate
```

## Inspecting Failures

To inspect the latest test result bundle:

```bash
xcrun xcresulttool get test-results summary --path <path-to-latest.xcresult>
```

A useful way to locate the latest result bundle:

```bash
ls -td ~/Library/Developer/Xcode/DerivedData/KeeForge-*/Logs/Test/*.xcresult | head -n 1
```

If `xcodebuild` cannot boot a simulator or reports missing destinations:

```bash
xcodebuild -showdestinations -project KeeForge.xcodeproj -scheme KeeForge
```

If the simulator gets stuck with "preflight checks":

```bash
xcrun simctl shutdown all && xcrun simctl erase <UDID>
```

## Adding UI Tests

- Prefer **small, focused test methods** over one giant end-to-end method
- Keep each test independent; do not rely on state left behind by a previous test method
- Start from a clean launch and use shared helpers like `unlockSuccessfully()`
- Use stable, fixture-backed assertions whenever possible
- Assert via accessibility identifiers first, visible labels second
- Promote repeated setup or navigation code into `KeeForgeUITestCase`
- Avoid assumptions based on incidental ordering like "first row" unless the fixture guarantees it
- UI tests should prove behavior, not exact layout or animation timing

Good patterns:

- one test method per behavior
- helpers that return to a known stable screen before the next assertion
- explicit waits for the element that proves state changed

Avoid:

- long tests that combine search, sort, settings, navigation, and modal flows in one method
- tests that depend on toolbar structure while search or sheets are still active
- assertions that guess at content instead of using known fixture data

## Fixing UI Tests

Fix the **test** when:

- labels or accessibility identifiers changed but the app still behaves correctly
- navigation assumptions are stale
- the test is too brittle or combines too many independent behaviors

Fix the **app** when:

- the intended user-visible behavior is actually broken
- an accessibility identifier or control that the product relies on disappeared
- the UI no longer exposes the expected feature

Common sources of UI test flakiness in this repo:

- search changes the visible view structure and toolbar contents
- sheets and menus replace the expected navigation controls
- the root fixture group contains subgroups, not direct entries
- document picker flows are asynchronous and require explicit waiting

When a test drives search, sorting, or modal UI, reset back to a known stable state before the next assertion. If a combined test keeps leaking state across sections, split it into multiple test methods.

## Fixtures

### Default Fixture

`TestFixtures/test.kdbx`  
Password: `testpassword123`

Contains:

- `Root` group (top-level, no entries directly)
- `Empty` group (0 entries)
- `Social` group: Twitter, Discord, Offline Key, Public Profile
- `Work` group: Email, GitHub

Important notes:

- the root group has only subgroups, no direct entries
- `openAnyEntry()` must navigate into a non-empty subgroup such as Social or Work
- `test.kdbx` does **not** contain passkeys or key-file-protected databases

### Demo Fixture

`TestFixtures/demo.kdbx`  
Password: `password`

Used by `AppStoreScreenshots` and richer screenshot-style flows.

### Key File Fixtures

- `test-binary.key`
- `test-hex.key`
- `test-v1.key`
- `test-v2.keyx`
- `test-arbitrary.key`
- `demo-keyfile.kdbx`
- `demo-keyfile.key`
- `test-v3-backup.kdbx`

Use `demo-keyfile.kdbx` with `demo-keyfile.key` for key-file UI testing.

## Base Class Helpers

`KeeForgeUITestCase` is the preferred base class for UI tests.

Key helpers:

- `app` — preconfigured `XCUIApplication` with fixture data injected through launch environment
- `unlock(password:)` — type password and tap unlock
- `unlockSuccessfully()` — unlock with the default fixture password and assert success
- `waitForVaultToUnlock()` — poll until unlock succeeds or surface the last visible error
- `openAnyEntry()` — navigate into a non-empty group and open an entry
- `revealElement(_:in:direction:maxSwipes:)` — scroll until an element is visible and hittable
- `waitForDocumentPicker()` — wait for the system document picker to appear

Prefer extending this base class over duplicating launch-environment setup or unlock logic in individual test files.

## Accessibility Hooks

Use the app's accessibility identifiers whenever possible, including:

- `unlock.password.field`
- `unlock.button`
- `unlock.error.label`
- `lock.button`
- `settings.button` (unlocked database)
- `database.settings.button` (database list)
- `sort.menu`
- `group.navlink`
- `entry.navlink`
- `entry.password.reveal`
- `entry.copy.password`
- `entry.copy.url`
- `entry.copy.totp`
- `search.results.count`
- `search.no-results`

If a new screen or interaction needs UI coverage, add an accessibility identifier as part of the feature work rather than relying on fragile label matching.
