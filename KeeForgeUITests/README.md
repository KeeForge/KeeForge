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
- `AutoFillStoreInspectorSmokeUITests` — DEBUG-only AutoFill store inspector smoke test; launches with `-autofill-store-inspector`, asserts the inspector presents at the app root and `autofill-inspector.enabled-state` reads "disabled" (safe on unprovisioned simulators). Does not extend `KeeForgeUITestCase` — the inspector replaces the normal root, so no fixture/unlock applies.

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

## AutoFill Store Harness Simulator

The AutoFill **store-validation** tests (the harness suite spec'd under
`docs/specs/2026-07-20-autofill-store-validation-harness/`) assert against the **real**
`ASCredentialIdentityStore`, which only goes live once a simulator has KeeForge enabled as its
system credential (AutoFill) provider. That state cannot be set from XCUITest — it lives in the
Settings app and persists on the device until it is erased. So those tests assume a dedicated,
one-time-provisioned simulator, **not** the default `iPhone 17 Pro` device the suites above use.
On any unprovisioned simulator the store is disabled and the harness tests skip cleanly
(`XCTSkip`) rather than fail.

### Provisioning

Run the provisioning script (local Mac only — it drives everything through `xcrun simctl`, no
Simulator.app required):

```bash
scripts/provision-autofill-harness-sim.sh
```

It resolves the newest installed iOS runtime and an iPhone-class device type, creates (or reuses)
a simulator named **`KeeForge-AutoFill-Harness`**, boots it, builds and installs the Debug
`KeeForge.app`, opens Settings, and then polls until KeeForge reports it is enabled. The one
manual step is printed while it polls:

> Settings → General → AutoFill & Passwords → turn **KeeForge** on (optionally turn Apple's
> "Passwords" provider off for a cleaner signal).

Flags:

- `--erase` — erase the device first for a from-scratch rebuild. **Erasing wipes provider
  enablement**, so you will have to flip the toggle again.
- `--app-path <path>` — install a prebuilt `.app` instead of building.
- `--timeout <seconds>` — verification poll timeout (default `300`); lower it to exercise the
  failure path quickly.

Verification uses a fixed app-side contract: launching the installed Debug build with
`-autofill-store-status-log` makes it emit exactly one machine-greppable line (via `print` and
NSLog), which the script reads from the simulator's unified log:

```
KEEFORGE-AUTOFILL-STORE-STATUS: enabled=<true|false> enumeration=<available|unavailable>
```

The script exits `0` only once it sees `enabled=true`. Distinct non-zero exits carry actionable
one-line messages: `3` duplicate harness devices (delete the extras), `6` the installed build
never emitted the status line (rebuild/reinstall a Debug build that supports the argument), `7`
verification timed out with the toggle still off, plus `2` usage, `4`/`5` build/install, `8`
missing `jq`/`xcrun`. The script header documents the full table and internal testing knobs.

### Re-verifying

Provider enablement persists until the device is erased, so a first successful run makes every
later run verify immediately with no manual step — re-run the script any time to confirm the
device is still provisioned. To rebuild from scratch (e.g. after an OS/runtime change), pass
`--erase` and flip the toggle again. To spot-check by hand, launch the installed build with the
slice-01 inspector argument (`-autofill-store-inspector`) and confirm
`autofill-inspector.enabled-state` reads "enabled".

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
- `unlockSuccessfully()` — unlock with the default fixture password and assert success; retries the whole unlock up to three times when the vault reports a wrong-password error (a race under CI's parallel simulators where the password is typed before the field/keyboard is ready), and only surfaces the real error on the final attempt
- `waitForVaultToUnlock()` — poll until unlock succeeds or surface the last visible error
- `KeeForgeUITestCase.ciElementTimeout` (15s) — shared, generous element-appearance timeout for spots that are slow to settle on Xcode Cloud's slower, four-way-parallel simulators; prefer it (over per-line 5s literals) for waits on the known-flaky paths
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
- `database-details.autofill-toggle` (database-details sheet, per-database AutoFill toggle)
- `settings.autofill.database-toggle.<database-id-uuidString>` (Settings → AutoFill per-database toggles; match with a BEGINSWITH predicate)
- `settings.autofill.clear-entries` / `settings.autofill.clear-entries.confirm` (Clear AutoFill Entries button + destructive confirmation; the confirm identifier matches two nested buttons — use `.firstMatch`)
- AutoFill store inspector (DEBUG-only; presented at the app root by the `-autofill-store-inspector` launch argument). Counts and states are exposed as element **values** (read `element.value`, not the label):
  - `autofill-inspector.enabled-state` (value `enabled` / `disabled`)
  - `autofill-inspector.enumeration-state` (value `available` / `unavailable`)
  - `autofill-inspector.total-count`
  - `autofill-inspector.refresh`
  - `autofill-inspector.database.<database-id-uuidString>.count` (uppercase UUID, same convention as `settings.autofill.database-toggle.<uuid>`)
  - `autofill-inspector.legacy.count` / `autofill-inspector.unrecognized.count` (rendered only when non-empty)

### DEBUG-only harness launch arguments

Two developer-tooling launch arguments (no effect in Release; wired in `../KeeForge/App/KeeForgeApp.swift`):

- `-autofill-store-inspector` — replaces the normal database-list root with the DEBUG AutoFill store inspector above.
- `-autofill-store-status-log` — at launch, queries the system store off-main and emits exactly one line to both stdout (`print`, captured by `simctl launch --console-pty`) and the unified log (`NSLog`):
  `KEEFORGE-AUTOFILL-STORE-STATUS: enabled=<true|false> enumeration=<available|unavailable>`.
  The provisioning script polls for this exact line. The argument is otherwise behavior-neutral and composes with `-autofill-store-inspector` (both can be passed together).

If a new screen or interaction needs UI coverage, add an accessibility identifier as part of the feature work rather than relying on fragile label matching.
