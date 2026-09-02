# KeeForge UI Tests

Detailed guidance for adding, running, and fixing XCUITests in `KeeForgeUITests/`.

Use this document for UI test methodology. Repo-wide build and test policy stays in `AGENTS.md`, and fixture details live in `../TestFixtures/README.md`.

macOS UI tests: see `../KeeForgeMacUITests/CLAUDE.md`; the accessibility identifiers are shared — preserve them in both.

## Current Test Classes

### Release-Smoke Oriented Classes

- `DatabaseListUITests` — home-screen database list actions and management
- `DatabaseCreationCompactUITests` — new local database happy path on compact / iPhone layout
- `UnlockFlowUITests` — basic unlock success/failure coverage
- `QuickLaunchSmokeUITests` — single-database quick-launch routing into unlock
- `LockUnlockUITests` — lock cycle coverage (`testManualLockBehavior`) and a single wrong-then-correct-password unlock (`testWrongThenCorrectPasswordUnlocks`); repeated-failure/lockout behavior is `BackoffUITests`' responsibility, not this class'
- `UnlockedDatabaseBrowseAndDetailUITests` — unlocked vault browse + entry-detail happy paths, the open-vault gear's complete Database Details surface, and the disabled KDBX 3.1 read-only control
- `UnlockedDatabaseSearchAndSortUITests` — unlocked search and sort happy paths, including folder captions on search results
- `EntryCreateSmokeUITests` — create-entry and create-group happy paths using a known fixture group
- `EntryEditSmokeUITests` — edit-entry happy path using a known fixture entry, including immediate title/username refresh in group lists, search, and title sorting plus a screenshot-backed regression check that a long revealed password wraps without extra characters
- `EntryDeleteSmokeUITests` — delete-entry happy paths using known fixture entries: row swipe/context-menu deletes, plus the entry editor's "Delete Entry" flow (`entry-edit.delete`) covering both dialog options and the already-recycled variant, asserting the editor dismisses back to a usable group list (regression cover for the permanent-delete wedge); plus group soft/permanent deletes and the Recycle Bin's no-delete guards
- `EntryRowCopyUITests` — the Copy Username / Copy Password items a long press adds to an entry row (`entry-row.copy-username-context`, `entry-row.copy-password-context`), asserted as offered and tappable; the pasteboard itself is never read, because reading it from the runner process raises the system paste prompt
- `EntryDuplicateUITests` — the Duplicate item on the same menu (`entry-row.duplicate-context`): it opens a New Entry form prefilled from the source, offering its destination group (`entry-edit.group`), and saving leaves both entries in the group
- `EntryAttachmentsSmokeUITests` — entry-attachments list happy path (row name/size, QuickLook preview open/dismiss) using the `kitchen-sink` fixture
- `EntryHistoryUITests` — entry history sheet happy path (`entry-detail.history` → version list → one version's fields) and the restore flow (`entry-history.restore` → `entry-history.restore.confirm`, asserting the replaced state is kept by reading the history row's accessibility **value**, not its localized label), using a fixture entry that ships stored `<History>`
- `ProtectedCustomFieldUITests` — protected custom fields start masked and reveal on demand in both entry detail and history, while retaining the established copy-control identifiers
- `GroupIconPickerUITests` — group icon picker round-trip (`group-row.change-icon-context` → pick `group-icon-picker.icon.37` → reopen and assert the cell reports `isSelected`) plus the cancel path leaving the icon alone
- `EntryIconPickerUITests` — entry icon picker round-trip from the entry-detail header (`entry-detail.icon-button` → pick `entry-icon-picker.standard.37` → reopen and assert the cell reports `isSelected`) plus the cancel path leaving the icon alone
- `EntryCustomIconPickerUITests` — custom-icon and favicon-download picker coverage on the `kitchen-sink` fixture, the only bundled database whose `Meta/CustomIcons` carries an image: picking the custom cell (`entry-icon-picker.custom.<uuid>`) round-trips as selected, picking a standard icon clears the custom selection (`<CustomIconUUID>` outranks `<IconID>`), an icon change pushes exactly one history version (asserted by count — the history screens expose no icon to accessibility), a read-only database (`UI_TEST_DATABASE_READ_ONLY=1`) renders the entry header with no `entry-detail.icon-button` at all, and "Download Website Icon" (`entry-icon-picker.download-favicon`) is enabled for an entry with a URL and disabled without one — asserted, never tapped, so no network is reached
- `GroupEditUITests` — group editor round-trip from the row context menu (`group-row.edit-context` → form → `group-edit.save`), covering rename, tags, notes, icon, Search & AutoFill visibility, cancel, duplicate-name errors, and the read-only/Recycle Bin entry-point restrictions. Extends `EntryEditUITestCase`
- `TagBrowserUITests` — tag-browser happy path (root `group-list.tags-row` → `tag-list.row.shared` with its entry count → folder-captioned tag results → entry detail's `entry-detail.tag.shared` chip), plus the hidden-group contract: entries leave search but remain available through tags. Uses the `kitchen-sink` fixture; the only fixture with entry tags. `shared` reaches four entries — two carry it, two inherit it from `Projects` — so the row's count is real data
- `InheritedTagsUITests` — entry detail draws the tags an entry gets from its groups (`entry-detail.inherited-tag.<tag>` under the `entry-detail.inherited-tags` strip), keeps them apart from the entry's own `entry-detail.tag.<tag>` chips, and navigates from an inherited chip into that tag's entries; uses the `kitchen-sink` fixture, the only bundled database with group `<Tags>`
- `TOTPSmokeUITests` — TOTP code renders (6-digit, numeric-only) and the copy control is present/hittable in entry detail, using the `autofill-union` fixture's "Union News" entry; deliberately does not assert exact code values or countdown timing
- `TOTPEnrollmentUITests` — entry-editor TOTP enrollment on the `autofill-union` fixture (base class `TOTPEnrollmentUITestCase`, shared with the deep-link class below): manual setup key on "Union Bank" (edit → `entry-edit.totp.enter-key` → reveal via `entry-edit.totp.secret-visibility-button` — the simulator has no passcode, so the device-owner gate falls through — → type a Base32 secret → save → `entry.totp.code` renders 6 numeric digits), pasted setup link on "Union Shop" (`entry-edit.totp.enter-link` → `entry-edit.totp.link-field`/`entry-edit.totp.link-apply`, non-default `digits=8&period=45` reflected in the form and an 8-digit code in detail), the invalid-link inline error (`entry-edit.totp.link-error`, sheet stays up, cancel leaves the entry pristine), and code removal on "Union News" (`entry-edit.totp.remove` → `entry-edit.totp.remove-confirm` → save → no `entry.totp.code` in detail). QR scanning is not covered — XCUITest cannot drive the simulator camera
- `TOTPEnrollmentDeepLinkUITests` — incoming `otpauth://` deep links. XCUITest cannot hand a URL to a running unlocked session (`XCUIDevice.shared.system.open` routes to the simulator's default code-setup app, Apple Passwords, only changeable in the Settings app; `XCUIApplication.open(_:)` relaunches the app to deliver the URL, discarding the in-memory session), so every flow drives the launched-with-URL park path — "Unlock a Database" alert → unlock → the sheet auto-promotes — and the direct-present-while-unlocked branch plus system-default routing stay manual device checks. Covered from there: attach to "Union Bank" → save → code renders, the replace confirmation for an entry that already has a code (`totp-enroll.replace-confirm`, plus editor-cancel returning to the destination list), the New Entry path (`totp-enroll.new-entry` → group picker → issuer-prefilled title → save), the unsupported-type (`otpauth://hotp/…`) alert, and the read-only explanation (`UI_TEST_DATABASE_READ_ONLY=1`)
- `KeyFileUnlockUITests` — unlocking with a key file
- `CloudBrowserSmokeUITests` — add Dropbox and browse the mock cloud picker
- `CloudUnlockSmokeUITests` — unlock a seeded cloud-backed database through the mock provider
- `WebDAVAddFlowUITests` — add WebDAV, fill the connect form, and browse the mock cloud picker (driven by `UITestWebDAVCloudProvider` via `UI_TEST_WEBDAV_PAYLOAD_JSON`)
- `WebDAVConnectErrorUITests` — WebDAV connect failure surfaces `webdav.connect.error` and keeps the form up
- `WebDAVSeededUnlockUITests` — unlock a seeded WebDAV cloud-backed database through the mock provider
- `DatabaseCreationRegularWidthUITests` — new local database happy path on regular-width / iPad layout
- `MasterKeyChangeUITests` — change-master-key happy path: create a local database, rotate its master password from Database Details (`database-details.change-master-key` → the `master-key.*` form, through the `master-key.confirm-change` confirmation dialog), lock, and unlock with the new password; the device-owner confirmation is a no-op under `-ui-testing`. Extends `DatabaseCreationUITestCase`
- `RegularWidthWorkspaceUITests` — regular-width / iPad workspace smoke coverage

### Secondary / Edge Coverage

- `BackoffUITests` — failed-unlock backoff behavior
- `AppSettingsUITests` — app settings / tip jar coverage from the database list
- `AutoFillTipUITests` — "Turn On AutoFill" banner on the database list (forced via `UI_TEST_SHOW_AUTOFILL_TIP=1`; the banner is suppressed in all other UI test classes and screenshots)
- `WhatsNewUITests` — feature-sheet structure and dismissal (forced via `UI_TEST_SHOW_WHATS_NEW=1`; the release sheet is suppressed in all other UI test classes and screenshots)
- `EntryEditEdgeUITests` — password generation, conflict handling, discard prompts, and read-only editing affordances
- `SaveConflictMergeUITests` — end-to-end "Merge Changes" on a real save conflict: a local title edit conflicts with a genuinely divergent on-disk copy, Merge reports the counted-changes "Changes Merged" summary (`merge-summary.ok`), and both the remote-only entry and the local edit survive with the unsaved-changes banner cleared
- `SaveConflictMergeDeclineUITests` — the declined-merge path on the `kitchen-sink` fixture: the divergent copy also grows a binary-pool field, so Merge reports "Couldn't Merge Changes" (`merge-failure.ok`), acknowledging it re-presents the conflict alert, and Cancel leaves the unsaved draft and its banner intact
- `KeyFileUITests` — key file selection and picker flows plus visible rejection of malformed XML key data during unlock
- `DocumentsVaultUITests` — Finder/iTunes File Sharing smoke coverage: a KDBX file seeded into Documents without a reference is auto-registered by the launch `DocumentsVaultScanner` scan and unlocks; a Documents-resident reference whose file is gone shows `database-row.documents-file-missing` and the unlock failure screen's `unlock.remove-missing` → confirm flow removes it from the list. Seeds via the `documents-*` `DatabaseFixture` dispositions (`documents`, `documents-unregistered`, `documents-missing`), which `DatabaseListStore`'s `-ui-testing` bootstrap materializes in the real Documents directory (scrubbing stale top-level `.kdbx` files from prior runs first). Finder replace/rebind edge cases stay unit-tested in `DocumentsVaultScannerTests`
- `CloudAccountEdgeUITests` — sign-out / disconnected cloud account behavior
- `AppStoreScreenshots` — screenshot capture flow using demo fixtures. **Opt-in only**: `setUp` `XCTSkip`s unless `APPSTORE_SCREENSHOTS=1` is set (mirrors `KeeForgeMacUITests/MacScreenshotAuditUITests`' `SCREENSHOT_AUDIT=1` gate):
  ```bash
  TEST_RUNNER_APPSTORE_SCREENSHOTS=1 xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:KeeForgeUITests/AppStoreScreenshots
  ```
  `TEST_RUNNER_APPSTORE_SCREENSHOTS` must be a real environment variable on the `xcodebuild` process itself (Xcode strips the `TEST_RUNNER_` prefix and forwards it into the test runner's environment) — verified empirically, passing it as a trailing bare `KEY=value` argument does not work and the test silently skips. Export the resulting attachments into `build/screenshots`, then run `ci_scripts/make_appstore_screenshots.py` to composite the final App Store images (see that script's header comment).
- `AutoFillStoreInspectorSmokeUITests` — DEBUG-only AutoFill store inspector smoke test; launches with `-autofill-store-inspector`, asserts the inspector presents at the app root and `autofill-inspector.enabled-state` reads "disabled" (safe on unprovisioned simulators). Does not extend `KeeForgeUITestCase` — the inspector replaces the normal root, so no fixture/unlock applies.

### Device-Only Classes

- `AutoFillStoreUITests` — store-lifecycle assertions against the **real** `ASCredentialIdentityStore`; runs only on a physical iPhone with KeeForge enabled as its credential provider (see the "AutoFill Store Device Tests" section) and all-skips everywhere else via its per-test skip guard.

Database-list and cloud UI tests are the current place to cover pending-upload badges / actions; the repo does not currently have automated coverage for the system AutoFill save sheet itself.

## Running UI Tests

Always run one UI test class at a time:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeUITests/UnlockedDatabaseBrowseAndDetailUITests -quiet
```

`-only-testing:` takes the **class** name, not the file name; run each class separately. Files hosting multiple classes:

- `UnlockedDatabaseUITests.swift` — `UnlockedDatabaseUITestCase` + `AppSettingsUITestCase` (bases), `UnlockedDatabaseBrowseAndDetailUITests`, `UnlockedDatabaseSearchAndSortUITests`, `RegularWidthWorkspaceUITests`, `AppSettingsUITests`, `EntryIconPickerUITests`, `EntryCustomIconPickerUITests`, `GroupIconPickerUITests`, `EntryHistoryUITests`, `ProtectedCustomFieldUITests`
- `EntryEditUITests.swift` — `EntryEditUITestCase` (base), `EntryCreateSmokeUITests`, `EntryEditSmokeUITests`, `EntryDeleteSmokeUITests`, `EntryEditEdgeUITests`
- `EntryDuplicateUITests.swift` — `EntryDuplicateUITests`
- `CloudSyncUITests.swift` — `CloudSyncBaseUITests` (base), `CloudBrowserSmokeUITests`, `CloudUnlockSmokeUITests`, `CloudAccountEdgeUITests`
- `WebDAVSyncUITests.swift` — `WebDAVSyncBaseUITests` (base), `WebDAVAddFlowUITests`, `WebDAVConnectErrorUITests`, `WebDAVSeededUnlockUITests`
- `DatabaseCreationUITests.swift` — `DatabaseCreationUITestCase` (base), `DatabaseCreationCompactUITests`, `DatabaseCreationRegularWidthUITests`
- `TOTPEnrollmentUITests.swift` — `TOTPEnrollmentUITestCase` (base), `TOTPEnrollmentUITests`, `TOTPEnrollmentDeepLinkUITests`
- `SaveConflictMergeUITests.swift` — `SaveConflictMergeUITestCase` (base, extends `EntryEditUITestCase`), `SaveConflictMergeUITests`, `SaveConflictMergeDeclineUITests`

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

Run policy (one class per run, no full suite, reproduce RC failures on the iOS 18 iPhone SE (3rd generation) simulator — compact-width, where minimum-OS regressions have surfaced) is in `AGENTS.md`.

## AutoFill Store Device Tests

The AutoFill **store-validation** tests (spec'd under
`docs/specs/2026-07-20-autofill-store-validation-harness/`) assert against the **real**
`ASCredentialIdentityStore`, which only goes live once KeeForge is enabled as the system
credential (AutoFill) provider — and simulator runtimes cannot enumerate the store at all
(`credentialIdentities(forService:)` reads empty despite persisted writes). So
`AutoFillStoreUITests` runs on a **physical iPhone** connected to the Mac, not a simulator.
On any simulator, or on a device where KeeForge is not the enabled provider, the store probe
fails its precondition and the tests skip cleanly (`XCTSkip`) rather than fail.

### Device preparation

One-time per device (the state persists until the app is uninstalled):

1. Connect the iPhone and pair it for development (it must appear under
   `xcodebuild -showdestinations`).
2. Install the Debug `KeeForge.app` (running the test target once does this).
3. In the device's Settings app: General → AutoFill & Passwords → turn **KeeForge** on
   (optionally turn Apple's "Passwords" provider off for a cleaner signal).

To spot-check the state at any time, launch the installed build with the inspector argument
(`-autofill-store-inspector`) and confirm `autofill-inspector.enabled-state` reads "enabled".

### Device Suite: `AutoFillStoreUITests`

The opt-in slice 03 class (`AutoFillStoreUITests.swift`) drives real app flows and asserts,
through the inspector, that the real system store ends up in the documented state for each
AutoFill lifecycle transition. Run it against the prepared device only:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS,name=<device name>' \
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
class is effectively excluded from the default suites: on any simulator (including the default
`iPhone 17 Pro`) it reports all-skipped quickly — only the first test pays a probe launch; the
result is cached for the rest of the process. Never add it to release-smoke selections; it is
opt-in by destination.

**Still manual / Tier-3** (not covered by this class): filling via the owning database and
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
- on iOS 27, buttons inside a `Section` of a SwiftUI `Menu` lose their accessibility identifiers (labels survive; direct menu children are unaffected). Query them with `menuButton(identifier:label:)` instead of `app.buttons["the.identifier"]`

When a test drives search, sorting, or modal UI, reset back to a known stable state before the next assertion. If a combined test keeps leaking state across sections, split it into multiple test methods.

## Injected Save Conflicts

Save-conflict flows are driven by a real divergent file, not a fabricated one. Under `-ui-testing`, `UI_TEST_LOCAL_SAVE_CONFLICT_COUNT=<n>` makes `LocalDatabaseSaver` rewrite the database on disk — before it compares hashes — for the first `n` local saves, adding a `UI Test Conflict <n>` entry to the visible root group (`DatabaseListStore.consumeUITestLocalSaveConflictSequence`). The open-time hash check then trips on its own, so the conflict, the remote bytes, and any merge against them are genuine. `UI_TEST_LOCAL_SAVE_CONFLICT_DIVERGES_POOL=1` additionally appends a binary-pool field to that rewritten copy, which is what makes `KDBXMerger` decline with the attachment-pool blocker on a fixture whose entries carry attachments.

Set the count to exactly the number of conflicts a test wants: a merge writes again, and a leftover count would inject a third version into that write instead of letting it land.

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

### Other Fixtures

Contents, regeneration scripts, and hashes are in `../TestFixtures/README.md`; this list only maps fixture → password → UI class.

- `TestFixtures/kitchen-sink.kdbx` (`testpassword123`) — `EntryAttachmentsSmokeUITests` and `SaveConflictMergeDeclineUITests` (the only UI-test fixture whose entries point into a binary pool), `TagBrowserUITests` (the only one with entry tags), `InheritedTagsUITests` (the only one with group `<Tags>`), `ProtectedCustomFieldUITests`, and `EntryCustomIconPickerUITests` (the only one with a `Meta/CustomIcons` image). Shared with the KDBX compatibility gate and the unit suites — retargeting or removing it breaks all three
- `TestFixtures/autofill-union.kdbx` (`testpassword123`) — `AutoFillStoreUITests` (second, "bravo" database, domain/username-disjoint from `test.kdbx`), `TOTPSmokeUITests`, `TOTPEnrollmentUITests`, `TOTPEnrollmentDeepLinkUITests`
- `TestFixtures/compatibility/legacy-kdbx31.kdbx` (`testpassword123`) — `UnlockedDatabaseBrowseAndDetailUITests.testLegacyKDBX31DatabaseDetailsKeepsReadOnlyToggleDisabled` (read-only KDBX 3.1)

### Key File Fixtures

Use `demo-keyfile.kdbx` (password `demo`) with `demo-keyfile.key` for the valid key-file unlock flow (`KeyFileUnlockUITests`). `invalid-xml.keyx` is bundled solely for `KeyFileUITests`' malformed-XML rejection case. The other key-file fixtures in `TestFixtures/` (`test-hex.key`, `test-v1.key`, `test-v2.keyx`, `test-arbitrary.key`) are bundled only into the unit-test targets and **not** available to UI tests.

### What The UI-Test Target Bundles

Exactly these fixtures ship in the UI-test bundle: `test.kdbx`, `demo.kdbx`, `demo-keyfile.kdbx`, `demo-keyfile.key`, and `kitchen-sink.kdbx` from the `UITestFixtures` target template in `project.yml` (shared with `KeeForgeMacUITests`, which bundles nothing else), plus this target's own extras — `invalid-xml.keyx`, `autofill-union.kdbx`, and `compatibility/legacy-kdbx31.kdbx`. To use another fixture from a UI test, add it to whichever of the two lists fits and run `xcodegen generate`.

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
- `menuButton(identifier:label:)` — match a menu item by accessibility identifier *or* visible label. Required for items inside a `Section` of a SwiftUI `Menu` (the toolbar add-database menu): the iOS 27 runtime drops accessibility identifiers from Section-wrapped menu buttons entirely — verified empirically, identifier on the Button, on its Label, and headerless `Section` all lose it, while direct menu children keep theirs — so identifier-only queries hang forever on iOS 27
- `openDatabaseDetails(rowContaining:)` / `closeDatabaseDetails()` — long-press a database row, open its Database Details context action, and wait for/dismiss the details sheet
- `setSwitch(_:isOn:)` — tap a switch until its raw `"1"`/`"0"` value matches. `UnlockFlowUITests`' private `setUsageStatsSwitch` stays separate because it tolerates other value encodings

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
- Entry editor One-Time Password section (`EntryEditView`): `entry-edit.totp.scan-qr` (iOS only) / `entry-edit.totp.enter-link` / `entry-edit.totp.enter-key` (entry paths when no TOTP is configured), `entry-edit.totp.secret-field` + `entry-edit.totp.secret-visibility-button`, `entry-edit.totp.period-field`, `entry-edit.totp.digits-picker` + `entry-edit.totp.digits-error`, `entry-edit.totp.algorithm-picker`, `entry-edit.totp.remove` (confirmed destructive, confirm `entry-edit.totp.remove-confirm` — matches nested buttons, use `.firstMatch`), the setup-link sheet's `entry-edit.totp.link-field` / `entry-edit.totp.link-error` / `entry-edit.totp.link-apply` / `entry-edit.totp.link-cancel`, and the QR scanner sheet's `entry-edit.totp.scan-cancel` (scanner is not UI-testable — no simulator camera)
- TOTP enrollment destination sheet (`TOTPEnrollmentDestinationView`, presented for an incoming `otpauth://` link): `totp-enroll.summary`, `totp-enroll.new-entry`, `totp-enroll.search-field`, `totp-enroll.entry-list`, `totp-enroll.entry.<entry-uuid>` (match with a BEGINSWITH predicate plus a label filter), `totp-enroll.group.<group-uuid>` (group-picker rows), `totp-enroll.replace-confirm` (matches nested buttons — use `.firstMatch`), `totp-enroll.cancel`. Anchor "did the sheet open" on the `Add Verification Code` navigation bar; the unlock-needed/invalid-link alerts are plain system alerts matched by title
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
- `entry-row.copy-username-context` / `entry-row.copy-password-context` (the copy pair every entry row's context menu leads with, on all three shells; each is absent when its field is empty, and the password one also needs an unlocked session)
- `group-row.edit-context` ("Edit Group", the first item of the group row context menu; the same identifier on the iOS/iPad row and the macOS sidebar row, and absent entirely on the Recycle Bin, inside it, and in a read-only database)
- Group editor (`GroupEditView`, pushed on iOS / a sheet on macOS):
  - `group-edit.name-field`
  - `group-edit.icon-button` (opens the shared `group-icon-picker.*` sheet)
  - `group-edit.tags` / `group-edit.tag.<normalized-tag>` (applied tag pills; the strip is an accessibility container, so the pills keep their own identifiers — same shape as `entry-edit.tags`, and it renders nothing when the group has no tags)
  - `group-edit.tags-field` (single-line; Return commits the typed tag)
  - `group-edit.tag-suggestions` / `group-edit.tag-suggestion.<normalized-tag>` (renders nothing when there is nothing left to suggest)
  - `group-edit.notes-field`
  - `group-edit.autofill-toggle` ("Hide from Search & AutoFill"; seeded from the *effective* exclusion, so it reads on for a group hidden by an ancestor)
  - `group-edit.cancel` / `group-edit.save` (Save is disabled until the form is dirty and the trimmed name non-empty)
  - `group-edit.saving-overlay`
- `autofill-tip.enable` / `autofill-tip.dismiss` (database-list AutoFill tip banner)
- `settings.autofill.turn-on` / `settings.autofill.open-ios-settings` (Settings → AutoFill provider status row)
- `settings.autofill.copy-totp` (Settings → AutoFill, copy-TOTP-after-fill toggle)
- `database-details.autofill-toggle` (database-details sheet, per-database AutoFill toggle)
- `database-details.change-master-key` (database-details sheet, session context only; pushes the Change Master Key screen, disabled while read-only)
- Change Master Key screen (`MasterKeyChangeView`, pushed inside the details sheet):
  - `master-key.new-password-field` / `master-key.new-password-visibility-button`
  - `master-key.confirm-password-field` / `master-key.confirm-password-visibility-button`
  - `master-key.keyfile.select` / `master-key.keyfile.clear`
  - `master-key.save` / `master-key.cancel`
  - `master-key.confirm-change` (destructive action in the confirmation dialog every save presents; matches nested buttons — use `.firstMatch`)
  - `master-key.error` (validation/change error banner)
- `settings.autofill.database-toggle.<database-id-uuidString>` (Settings → AutoFill per-database toggles; match with a BEGINSWITH predicate)
- `settings.autofill.clear-entries` / `settings.autofill.clear-entries.confirm` (Clear AutoFill Entries button + destructive confirmation; the confirm identifier matches two nested buttons — use `.firstMatch`)
- AutoFill store inspector (DEBUG-only; presented at the app root by the `-autofill-store-inspector` launch argument, wired in `../KeeForge/App/KeeForgeApp.swift`; no effect in Release). Counts and states are exposed as element **values** (read `element.value`, not the label):
  - `autofill-inspector.enabled-state` (value `enabled` / `disabled`)
  - `autofill-inspector.total-count`
  - `autofill-inspector.refresh`
  - `autofill-inspector.database.<database-id-uuidString>.count` (uppercase UUID, same convention as `settings.autofill.database-toggle.<uuid>`)
  - `autofill-inspector.legacy.count` / `autofill-inspector.unrecognized.count` (rendered only when non-empty)

  **Simulator enumeration caveat.** On simulator runtimes (verified iOS 18.5 and 26.5) the enumeration API `ASCredentialIdentityStore.credentialIdentities(...)` always returns an *empty array* despite persisted writes (the saves succeed and QuickType consumes them). The inspector's counts — and the app's own enumerate-then-mutate store maintenance (`CredentialIdentityStoreManager.populate` / `removeIdentities(forDatabase:)`) — are therefore only meaningful on a physical device.

  **Why `AutoFillStoreUITests` uses two disjoint fixtures.** The system store can dedup identities sharing `(service_id, user)` across databases, ignoring `recordIdentifier`. `AutoFillStoreUITests` therefore seeds its second ("bravo") database from `autofill-union.kdbx`, fully domain/username-disjoint from `test.kdbx` ("alpha") — see `../TestFixtures/README.md` — so no cross-database dedup can occur and `testMultiDatabaseUnionAndSingleSectionRemoval` deterministically asserts the full union: inspector total = alpha's count + bravo's, each section holds its own full set, and disabling bravo removes only its section.

If a new screen or interaction needs UI coverage, add an accessibility identifier as part of the feature work rather than relying on fragile label matching.
