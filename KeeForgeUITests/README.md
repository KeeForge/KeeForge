# KeeForge UI Tests

Detailed guidance for adding, running, and fixing XCUITests in `KeeForgeUITests/`.

Use this document for UI test methodology. Repo-wide build and test policy stays in `AGENTS.md`, and fixture details live in `../TestFixtures/README.md`.

## macOS Smoke Suite

The macOS port has its own UI-test target, `KeeForgeMacUITests/` (target `KeeForgeMacUITests`, scheme `KeeForgeMac`), with a Mac-flavored base class `MacUITestCase` that mirrors this target's fixture-injection launch environment but uses clicks, `typeKey` keyboard shortcuts, and right-click context menus instead of taps/swipes. It reuses the same accessibility identifiers as this suite — preserve them in both places. Notes specific to the Mac suite:

- Run with `xcodebuild test -scheme KeeForgeMac -destination 'platform=macOS,arch=arm64' -only-testing:KeeForgeMacUITests/<Class>`.
- macOS UI tests require an unlocked, active login session; they fail with "Failed to activate application (Running Background)" when the screen is locked.
- `MacUITestCase` launches with `-ApplePersistenceIgnoreState YES`; without it, macOS state restoration can restore a zero-window session and no main window ever appears.
- Reveal/copy-password tests assert up to the device-owner auth prompt boundary (the prompt is a system dialog XCUITest cannot automate); terminating the app in teardown dismisses it.

## Current Test Classes

### Release-Smoke Oriented Classes

- `DatabaseListUITests` — home-screen database list actions and management
- `DatabaseCreationCompactUITests` — new local database happy path on compact / iPhone layout
- `UnlockFlowUITests` — basic unlock success/failure coverage
- `QuickLaunchSmokeUITests` — single-database quick-launch routing into unlock
- `LockUnlockUITests` — lock cycle coverage
- `UnlockedDatabaseBrowseAndDetailUITests` — unlocked vault browse + entry-detail happy paths
- `UnlockedDatabaseSearchAndSortUITests` — unlocked search and sort happy paths
- `EntryCreateSmokeUITests` — create-entry happy path using a known fixture group
- `EntryEditSmokeUITests` — edit-entry happy path using a known fixture entry
- `EntryDeleteSmokeUITests` — delete-entry happy path using a known fixture entry
- `EntryAttachmentsSmokeUITests` — entry-attachments list happy path (row name/size, QuickLook preview open/dismiss) using the `attachments` fixture
- `KeyFileUnlockUITests` — unlocking with a key file
- `CloudBrowserSmokeUITests` — add Dropbox and browse the mock cloud picker
- `CloudUnlockSmokeUITests` — unlock a seeded cloud-backed database through the mock provider
- `WebDAVAddFlowUITests` — add WebDAV, fill the connect form, and browse the mock cloud picker (driven by `UITestWebDAVCloudProvider` via `UI_TEST_WEBDAV_PAYLOAD_JSON`)
- `WebDAVConnectErrorUITests` — WebDAV connect failure surfaces `webdav.connect.error` and keeps the form up
- `WebDAVSeededUnlockUITests` — unlock a seeded WebDAV cloud-backed database through the mock provider
- `DatabaseCreationRegularWidthUITests` — new local database happy path on regular-width / iPad layout
- `RegularWidthWorkspaceUITests` — regular-width / iPad workspace smoke coverage

### Secondary / Edge Coverage

- `BackoffUITests` — failed-unlock backoff behavior
- `AppSettingsUITests` — app settings / tip jar coverage from the database list
- `AutoFillTipUITests` — "Turn On AutoFill" banner on the database list (forced via `UI_TEST_SHOW_AUTOFILL_TIP=1`; the banner is suppressed in all other UI test classes and screenshots)
- `WhatsNewUITests` — feature-sheet structure and dismissal (forced via `UI_TEST_SHOW_WHATS_NEW=1`; the release sheet is suppressed in all other UI test classes and screenshots)
- `EntryEditEdgeUITests` — password generation, conflict handling, discard prompts, and read-only editing affordances
- `KeyFileUITests` — key file selection and picker flows
- `CloudAccountEdgeUITests` — sign-out / disconnected cloud account behavior
- `AppStoreScreenshots` — screenshot capture flow using demo fixtures

Database-list and cloud UI tests are the current place to cover pending-upload badges / actions; the repo does not currently have a dedicated simulator harness for the system AutoFill save sheet itself.

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
# One release-smoke unlocked class
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/UnlockedDatabaseSearchAndSortUITests -quiet

# Key file-specific class from a shared source file
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/KeyFileUnlockUITests -quiet

# Entry creation smoke slice
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/EntryCreateSmokeUITests -quiet

# New local database creation smoke slice
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/DatabaseCreationCompactUITests -quiet

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' \
  -only-testing:KeeForgeUITests/DatabaseCreationRegularWidthUITests -quiet

# Cloud-backed smoke slice
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/CloudUnlockSmokeUITests -quiet

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
- for save-path smoke assertions, reopen the target group before checking persisted list content
- explicit waits for the element that proves state changed
- tests that need Quick Launch should enable it explicitly in `configureLaunch(app:)` instead of relying on the single-database default

Avoid:

- long tests that combine smoke-path coverage and edge-case coverage in the same class
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
- password-filled create flows can trigger the system `Save Password?` sheet in the simulator
- regular-width workspace and database-details smoke flows are much more stable when they target dedicated accessibility identifiers such as `regular-workspace.select-entry-placeholder` and `database-details.quick-launch-toggle`

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
Password: `demo`

Used by `AppStoreScreenshots` and richer screenshot-style flows.

### Attachments Fixture

`TestFixtures/compatibility/attachments.kdbx`  
Password: `testpassword123`

Used by `EntryAttachmentsSmokeUITests`. Single `Attachments` group with `Multi Attachment Entry` (attachments `note-ü.txt` and `pixel.png`), `Dedup Entry A` / `Dedup Entry B` (both attach identically-named/identical-content `shared.bin`), and `No Attachment Entry`. See `../TestFixtures/README.md` for recorded SHA-256 hashes.

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
- `openDatabase(named:)` — open a known fixture-backed database row instead of whichever row appears first
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
- `database-row.read-only-toggle`
- `database-row.read-only-badge`
- `database-row.pending-uploads-badge`
- `database-row.push-pending-action`
- `search.results.count`
- `search.no-results`
- `autofill-tip.enable` / `autofill-tip.dismiss` (database-list AutoFill tip banner)
- `settings.autofill.turn-on` / `settings.autofill.open-ios-settings` (Settings → AutoFill provider status row)

If a new screen or interaction needs UI coverage, add an accessibility identifier as part of the feature work rather than relying on fragile label matching.
