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
- `LockUnlockUITests` — lock cycle coverage (`testManualLockBehavior`) and a single wrong-then-correct-password unlock (`testWrongThenCorrectPasswordUnlocks`); repeated-failure/lockout behavior is `BackoffUITests`' responsibility, not this class'
- `UnlockedDatabaseBrowseAndDetailUITests` — unlocked vault browse + entry-detail happy paths
- `UnlockedDatabaseSearchAndSortUITests` — unlocked search and sort happy paths
- `EntryCreateSmokeUITests` — create-entry happy path using a known fixture group
- `EntryEditSmokeUITests` — edit-entry happy path using a known fixture entry, including a screenshot-backed regression check that a long revealed password wraps without extra characters
- `EntryDeleteSmokeUITests` — delete-entry happy paths using known fixture entries: row swipe/context-menu deletes, plus the entry editor's "Delete Entry" flow (`entry-edit.delete`) covering both dialog options and the already-recycled variant, asserting the editor dismisses back to a usable group list (regression cover for the v1.10.4 permanent-delete wedge)
- `EntryAttachmentsSmokeUITests` — entry-attachments list happy path (row name/size, QuickLook preview open/dismiss) using the `attachments` fixture
- `EntryHistoryUITests` — entry history sheet happy path (`entry-detail.history` → version list → one version's fields) and the restore flow (`entry-history.restore` → `entry-history.restore.confirm`, asserting the replaced state is kept by reading the history row's accessibility **value**, not its localized label), using a fixture entry that ships stored `<History>`
- `ProtectedCustomFieldUITests` — protected custom fields start masked and reveal on demand in both entry detail and history, while retaining the established copy-control identifiers
- `GroupIconPickerUITests` — group icon picker round-trip (`group-row.change-icon-context` → pick `group-icon-picker.icon.37` → reopen and assert the cell reports `isSelected`) plus the cancel path leaving the icon alone
- `TagBrowserUITests` — tag-browser happy path (root `group-list.tags-row` → `tag-list.row.shared` with its entry count → the tag's entries → entry detail's `entry-detail.tag.shared` chip) using the `tag-browser` fixture; the only fixture with entry tags
- `InheritedTagsUITests` — entry detail draws the tags an entry gets from its groups (`entry-detail.inherited-tag.<tag>` under the `entry-detail.inherited-tags` strip), keeps them apart from the entry's own `entry-detail.tag.<tag>` chips, and navigates from an inherited chip into that tag's entries; uses the `group-tags` fixture, the only bundled database with group `<Tags>`
- `TOTPSmokeUITests` — TOTP code renders (6-digit, numeric-only) and the copy control is present/hittable in entry detail, using the `autofill-union` fixture's "Union News" entry; deliberately does not assert exact code values or countdown timing
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
- `AppStoreScreenshots` — screenshot capture flow using demo fixtures. **Opt-in only**: `setUp` `XCTSkip`s unless `APPSTORE_SCREENSHOTS=1` is set (mirrors `KeeForgeMacUITests/MacScreenshotAuditUITests`' `SCREENSHOT_AUDIT=1` gate), so it no longer runs — with its ~15+ s of hard `sleep()`s — on every full `KeeForgeUITests` invocation, including both RC release gates:
  ```bash
  TEST_RUNNER_APPSTORE_SCREENSHOTS=1 xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:KeeForgeUITests/AppStoreScreenshots
  ```
  `TEST_RUNNER_APPSTORE_SCREENSHOTS` must be a real environment variable on the `xcodebuild` process itself (Xcode strips the `TEST_RUNNER_` prefix and forwards it into the test runner's environment) — verified empirically, passing it as a trailing bare `KEY=value` argument does not work and the test silently skips. Export the resulting attachments into `build/screenshots`, then run `ci_scripts/make_appstore_screenshots.py` to composite the final App Store images (see that script's header comment).
- `AutoFillStoreInspectorSmokeUITests` — DEBUG-only AutoFill store inspector smoke test; launches with `-autofill-store-inspector`, asserts the inspector presents at the app root and `autofill-inspector.enabled-state` reads "disabled" (safe on unprovisioned simulators). Does not extend `KeeForgeUITestCase` — the inspector replaces the normal root, so no fixture/unlock applies.

### Harness-Only Classes

- `AutoFillStoreUITests` — store-lifecycle assertions against the **real** `ASCredentialIdentityStore`; runs only on the provisioned harness simulator (see the next section) and all-skips everywhere else via its per-test skip guard.

Database-list and cloud UI tests are the current place to cover pending-upload badges / actions; the repo does not currently have a dedicated simulator harness for the system AutoFill save sheet itself.

## Running UI Tests

Always run one UI test class at a time:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/UnlockedDatabaseBrowseAndDetailUITests -quiet
```

`-only-testing:` takes the **class** name, not the file name; run each class separately. Files hosting multiple classes:

- `UnlockedDatabaseUITests.swift` — `UnlockedDatabaseUITestCase` + `AppSettingsUITestCase` (bases), `UnlockedDatabaseBrowseAndDetailUITests`, `UnlockedDatabaseSearchAndSortUITests`, `RegularWidthWorkspaceUITests`, `AppSettingsUITests`, `GroupIconPickerUITests`, `EntryHistoryUITests`, `ProtectedCustomFieldUITests`
- `EntryEditUITests.swift` — `EntryEditUITestCase` (base), `EntryCreateSmokeUITests`, `EntryEditSmokeUITests`, `EntryDeleteSmokeUITests`, `EntryEditEdgeUITests`
- `CloudSyncUITests.swift` — `CloudSyncBaseUITests` (base), `CloudBrowserSmokeUITests`, `CloudUnlockSmokeUITests`, `CloudAccountEdgeUITests`
- `WebDAVSyncUITests.swift` — `WebDAVSyncBaseUITests` (base), `WebDAVAddFlowUITests`, `WebDAVConnectErrorUITests`, `WebDAVSeededUnlockUITests`
- `DatabaseCreationUITests.swift` — `DatabaseCreationUITestCase` (base), `DatabaseCreationCompactUITests`, `DatabaseCreationRegularWidthUITests`

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

### CI: iOS 18 RC Workflow

Pushing an `rc/*` tag triggers `.github/workflows/ios18-rc-tests.yml`, which runs the suites on an **iPhone SE (3rd generation)** simulator with an iOS 18 runtime (compact-width — where minimum-OS regressions have surfaced). Reproduce RC failures on that device and runtime, not the default `iPhone 17 Pro`.

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
missing `jq`/`xcrun`, `9` runtime/device-type resolution, `10` bad `--app-path`. The script
header documents the full table and internal testing knobs.

### Re-verifying

Provider enablement persists until the device is erased, so a first successful run makes every
later run verify immediately with no manual step — re-run the script any time to confirm the
device is still provisioned. To rebuild from scratch (e.g. after an OS/runtime change), pass
`--erase` and flip the toggle again. To spot-check by hand, launch the installed build with the
slice-01 inspector argument (`-autofill-store-inspector`) and confirm
`autofill-inspector.enabled-state` reads "enabled".

### Harness Suite: `AutoFillStoreUITests`

The opt-in slice 03 class (`AutoFillStoreUITests.swift`) drives real app flows and asserts,
through the inspector, that the real system store ends up in the documented state for each
AutoFill lifecycle transition. Run it against the harness simulator only:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=KeeForge-AutoFill-Harness' \
  -only-testing:KeeForgeUITests/AutoFillStoreUITests
```

**Covered lifecycle scenarios** (identity presence and ownership in the store — never
Safari/QuickType behavior):

1. Publication on unlock — the unlocked database's tagged section appears with its full
   eligible-identity count; a never-unlocked database has no section.
2. Targeted removal on per-database disable (details-sheet toggle, database locked) — that
   section empties; the store stays enabled and enumerable.
3. Lazy republish on re-enable — count stays zero after re-enabling; the database's next
   unlock (same reference, across relaunches) republishes.
4. Clear AutoFill Entries — with identities verified present, the confirmed clear action
   brings the total count to zero.
5. Multi-database union and single-section removal — two unlocked databases hold their
   sections simultaneously; disabling one (Settings toggle) removes only its section.

**Skip guard / exclusion from normal runs.** Every test's `setUp` probes the store through the
inspector first and `XCTSkip`s when the store is disabled or enumeration is unavailable, so the
class is effectively excluded from the default suites: on any unprovisioned simulator
(including the default `iPhone 17 Pro`) it reports all-skipped quickly — only the first test
pays a probe launch; the result is cached for the rest of the process. Never add it to
release-smoke selections; it is opt-in by destination.

**Replaced manual checks** from
[`docs/specs/2026-07-19-selectable-autofill-per-database/deferred-tests.md`](../docs/specs/2026-07-19-selectable-autofill-per-database/deferred-tests.md)
(the store-state halves; anything QuickType/Safari-visible stays with the Tier-3 agent
routine):

- Slice 04 manual — "Unlock Personal, then Work: QuickType shows entries from both": the
  both-databases-published union is now asserted at the store level (scenario 5). "Disable
  Work while locked: its suggestions vanish, Personal's remain": automated (scenarios 2 and 5).
- Slice 05 manual — "Disable a database (while it is locked): its suggestions disappear …
  Re-enable: suggestions return only after its next unlock": automated (scenarios 2 and 3).
  "Clear AutoFill Entries → confirm: QuickType is empty … unlock an enabled database and watch
  its suggestions return": automated at the store level (scenarios 4 and 3; the cancel path was
  already covered by `AppSettingsUITests.testAutoFillSettingsListsDatabaseTogglesAndCancelableClear`).

**Still manual / Tier-3** (not replaced by this class): filling via the owning database and
every other QuickType/Safari-rendered check, extension flows (save, switcher, empty state),
entry-deletion suggestion sweeps, database *removal* cleanup, immediate republish when
re-enabling the currently open database, and the localized-UI (`de`/`fr`/`es`) and VoiceOver passes.

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
- a row below the fold on a 375x667 screen (iPhone SE) is never materialized by a lazy `List`/`Form`, so `waitForExistence` on it can only time out however generous the timeout. Anchor "did this screen open" assertions on a navigation bar or toolbar item, and `revealElement` anything further down. Two tests failed this way on an iOS 26.5 iPhone SE: the AutoFill settings per-database toggles (pushed past the fold by the Copy Verification Code footer) and the entry-history version screen's Last Modified row
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

### AutoFill Union Fixture

`TestFixtures/autofill-union.kdbx`  
Password: `testpassword123`

Used by `AutoFillStoreUITests` as its second ("bravo") database: one `Union` group whose three entries publish exactly 3 password + 1 one-time-code AutoFill identities, with every service domain and username disjoint from `test.kdbx`'s — the simulator's credential-identity store dedups identities sharing a (service, user) pair across databases, so the multi-database union scenario needs non-overlapping fixtures. Details and regeneration recipe in `../TestFixtures/README.md`.

### Tag Browser Fixture

`TestFixtures/tag-browser.kdbx`  
Password: `testpassword123`

Used by `TagBrowserUITests`. The only bundled fixture with entry tags — `test.kdbx` and `demo.kdbx` have none. `Tagged` group: `Router Admin` (`shared`, `Work`, `Personal Notes`), `Mail Account` (`shared`, `work`), `Untagged Entry`; `Archive` group: `Old Backup` (`archive`). Regenerate with `TestFixtures/generate_tag_browser_fixture.py`; details in `../TestFixtures/README.md`.

### Group Tags Fixture

`TestFixtures/compatibility/group-tags.kdbx`  
Password: `testpassword123`

Used by `InheritedTagsUITests`. The only bundled fixture with group `<Tags>` — `tag-browser.kdbx` carries entry tags only. `Projects` (group tags `team;shared`) holds `Alpha Login`; `Projects/Client Work` (group tag `billable`) holds `Beta Login`, which adds its own entry tag `own-tag`; `Empty Tags Group`, `Plain Group`, and a `Recycle Bin` cover the remaining `<Tags>` states. Shared with the KDBX compatibility gate — retargeting or removing it breaks both. Regenerate with `TestFixtures/compatibility/generate_group_tags_fixture.py`; details in `../TestFixtures/README.md`.

### Protected Custom Field Fixture

`TestFixtures/protected-custom-field.kdbx`

Password: `testpassword123`

Used by `ProtectedCustomFieldUITests`. `Secrets/Protected Custom` carries a protected `API Token` custom field in both the current entry and one stored history version.

### Key File Fixtures

Use `demo-keyfile.kdbx` with `demo-keyfile.key` — the only key-file pair bundled into `KeeForgeUITests`. The other key-file fixtures in `TestFixtures/` (`test-binary.key`, `test-hex.key`, `test-v1.key`, `test-v2.keyx`, `test-arbitrary.key`, `test-v3-backup.kdbx`) are bundled only into the unit-test targets and **not** available to UI tests.

### What The UI-Test Target Bundles

Per the `KeeForgeUITests` sources in `project.yml`, exactly these fixtures ship in the UI-test bundle: `test.kdbx`, `demo.kdbx`, `demo-keyfile.kdbx`, `demo-keyfile.key`, `compatibility/attachments.kdbx`, `autofill-union.kdbx`, `tag-browser.kdbx`, and `protected-custom-field.kdbx`. To use another fixture from a UI test, add it there and run `xcodegen generate`.

Loading mechanism: fixtures are injected through the launch environment by `KeeForgeUITestCase.setUp` (base64 of the bundled resource in `UI_TEST_DATABASES_JSON`), so a test only overrides `databaseFixtureName` — it never touches file paths. The name must match the resource added to `project.yml`.

## Base Class Helpers

`KeeForgeUITestCase` is the preferred base class for UI tests.

Key helpers:

- `app` — preconfigured `XCUIApplication` with fixture data injected through launch environment
- `unlock(password:)` — type password and tap unlock
- `unlockSuccessfully()` — unlock with the default fixture password and assert success; retries the whole unlock up to three times when the vault reports a wrong-password error (a race under CI's parallel simulators where the password is typed before the field/keyboard is ready), and only surfaces the real error on the final attempt
- `waitForVaultToUnlock()` — poll until unlock succeeds or surface the last visible error
- `replaceText(in:with:)` — clear a field and type into it; first scrolls the field clear of the software keyboard and re-taps it until a keyboard is up, because `typeText` on an unfocused field fails the test outright ("Neither element nor any descendant has keyboard focus") and cannot be caught and retried. `XCUIElement.hasFocus` is not usable as the readiness signal — SwiftUI text fields report `false` even while focused
- `KeeForgeUITestCase.ciElementTimeout` (15s) — shared, generous element-appearance timeout for spots that are slow to settle on Xcode Cloud's slower, four-way-parallel simulators; prefer it (over per-line 5s literals) for waits on the known-flaky paths
- `openDatabase(named:)` — open a known fixture-backed database row instead of whichever row appears first
- `openAnyEntry()` — navigate into a non-empty group and open an entry
- `revealElement(_:in:direction:maxSwipes:)` — scroll until an element is visible and hittable
- `waitForDocumentPicker()` — wait for the system document picker to appear
- `openDatabaseDetails(rowContaining:)` / `closeDatabaseDetails()` — long-press a database row, open its Database Details context action, and wait for/dismiss the details sheet. Promoted from byte-for-byte-duplicated private copies in `DatabaseListUITests` and `AutoFillStoreUITests`
- `setSwitch(_:isOn:)` — tap a switch until its raw `"1"`/`"0"` value matches the desired state. Promoted from near-duplicate private copies in `DatabaseListUITests` and `AutoFillStoreUITests` that had drifted apart in their failure-message text ("Expected AutoFill toggle to be ..." vs. the more generic "Expected toggle to be ..."); the generic message won since `AutoFillStoreUITests` exercises this against several different toggles, not just one. Distinct from `UnlockFlowUITests`' private `setUsageStatsSwitch`, which tolerates additional value encodings ("on"/off strings, `NSNumber`) that this stricter shared helper does not — kept separate deliberately rather than merged, to avoid changing that test's behavior

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
- `entry.totp.code` (entry detail, the rendered TOTP code `Text`; read `.label`, not `.value`)
- `settings.security.link` (Settings → Security)
- `settings.security.lock-on-background-toggle` (Settings → Security, "Lock When App Goes to Background" toggle — the closest real protective toggle on the iOS Security screen; iOS has no screen-capture-block toggle, that setting is macOS-only)
- `database-row.read-only-toggle`
- `database-row.read-only-badge`
- `database-row.pending-uploads-badge`
- `database-row.push-pending-action`
- `search.results.count`
- `search.no-results`
- `group-list.tags-row` (root group list, tag-browser entry point)
- `tag-list` / `tag-list.row.<normalized-tag>` (tag list rows; the macOS sidebar's tag rows reuse the row identifier)
- `tag-entries.list` (a tag's filtered entry list; its rows keep `EntryListView`'s `search.entry.navlink`)
- `entry-detail.tag.<normalized-tag>` (entry-detail tag chips)
- `autofill-tip.enable` / `autofill-tip.dismiss` (database-list AutoFill tip banner)
- `settings.autofill.turn-on` / `settings.autofill.open-ios-settings` (Settings → AutoFill provider status row)
- `settings.autofill.copy-totp` (Settings → AutoFill, copy-TOTP-after-fill toggle)
- `database-details.autofill-toggle` (database-details sheet, per-database AutoFill toggle)
- `settings.autofill.database-toggle.<database-id-uuidString>` (Settings → AutoFill per-database toggles; match with a BEGINSWITH predicate)
- `settings.autofill.clear-entries` / `settings.autofill.clear-entries.confirm` (Clear AutoFill Entries button + destructive confirmation; the confirm identifier matches two nested buttons — use `.firstMatch`)
- AutoFill store inspector (DEBUG-only; presented at the app root by the `-autofill-store-inspector` launch argument). Counts and states are exposed as element **values** (read `element.value`, not the label):
  - `autofill-inspector.enabled-state` (value `enabled` / `disabled`)
  - `autofill-inspector.enumeration-state` (value `available` / `unavailable`)
  - `autofill-inspector.total-count`
  - `autofill-inspector.source` (value `api` / `fallback-db` — which channel supplied the identity rows; see the note below)
  - `autofill-inspector.refresh`
  - `autofill-inspector.database.<database-id-uuidString>.count` (uppercase UUID, same convention as `settings.autofill.database-toggle.<uuid>`)
  - `autofill-inspector.legacy.count` / `autofill-inspector.unrecognized.count` (rendered only when non-empty)

  **Simulator enumeration caveat / seam-level fallback.** On simulator runtimes (verified iOS 18.5 and 26.5) the enumeration API `ASCredentialIdentityStore.credentialIdentities(...)` always returns an *empty array* despite persisted writes (the saves succeed and QuickType consumes them). This breaks not only the inspector but the app's *own* store maintenance (`CredentialIdentityStoreManager.populate` / `removeIdentities(forDatabase:)` enumerate-then-mutate). The fix is a single DEBUG + simulator-only fallback at the store seam (`SystemCredentialIdentityStore.credentialIdentities()`): when the API returns empty it reconstructs the real identities from the backing SQLite file (`<app-data-container>/SystemData/com.apple.AuthenticationServices/Identities/Identities.db`, read-only, metadata + public passkey identifiers only), so per-database maintenance behaves device-equivalently on simulators. The inspector surfaces which channel served the rows via `autofill-inspector.source` = `api` (API served, or everything empty) / `fallback-db` (seam read the backing DB). `autofill-inspector.total-count` and the per-database/legacy/unrecognized rows therefore reflect the true store contents on the harness even though the API reads empty. **`autofill-inspector.enumeration-state` stays API-truth** (`available` when the API returns a non-nil array — which on the harness it does, just empty — `unavailable` only when the API returns nil, e.g. macOS 14.0–14.3): it is *not* affected by the fallback and does not indicate whether rows were found.

  **Write-side simulator dedup (why `AutoFillStoreUITests` uses two disjoint fixtures).** Separately from the enumeration read bug, the simulator's `saveCredentialIdentities` dedups identities sharing `(service_id, user)` across databases, ignoring `recordIdentifier` (verified on the harness: two databases' identical-domain identities collapse to one database's set). `AutoFillStoreUITests` therefore seeds its second ("bravo") database from `autofill-union.kdbx`, fully domain/username-disjoint from `test.kdbx` ("alpha") — see the AutoFill Union Fixture section above — so no cross-database dedup can occur and `testMultiDatabaseUnionAndSingleSectionRemoval` deterministically asserts the full union: inspector total = alpha's count + bravo's, each section holds its own full set, and disabling bravo removes only its section.

### DEBUG-only harness launch arguments

Two developer-tooling launch arguments (no effect in Release; wired in `../KeeForge/App/KeeForgeApp.swift`):

- `-autofill-store-inspector` — replaces the normal database-list root with the DEBUG AutoFill store inspector above.
- `-autofill-store-status-log` — at launch, queries the system store off-main and emits exactly one line to both stdout (`print`, captured by `simctl launch --console-pty`) and the unified log (`NSLog`):
  `KEEFORGE-AUTOFILL-STORE-STATUS: enabled=<true|false> enumeration=<available|unavailable>`.
  The provisioning script polls for this exact line. The argument is otherwise behavior-neutral and composes with `-autofill-store-inspector` (both can be passed together).

If a new screen or interaction needs UI coverage, add an accessibility identifier as part of the feature work rather than relying on fragile label matching.
