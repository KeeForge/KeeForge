# KeeForgeUITests

**Scope:** XCUITest suites for iPhone and iPad. The Mac suite is in `../KeeForgeMacUITests/AGENTS.md`; both use the same accessibility identifiers and fixture-injection environment, so a change to either affects both.

## Running

Base commands and repo-wide policy (`-only-testing:` always, no full UI suite unless asked, RC failures on the iOS 18 iPhone SE simulator) are in `../AGENTS.md`. Specific to this target:

- Run one class per invocation. `-only-testing:KeeForgeUITests/<Class>` takes the class name, not the file name, and several files hold many classes, so grep for the class.
- Pass `-test-timeouts-enabled YES` locally. `KeeForgeUITestCase` sets a 300 s per-test allowance that is enforced only with it; Xcode Cloud already enables it.
- Xcode Cloud splits this target into `KeeForgeCloudUIA` (a class list in `project.yml`) and `KeeForgeCloudUIB` (its complement, so a new class lands in B). Renaming or deleting a class in A needs the list updated; see `../ci_scripts/AGENTS.md`.
- Layout-gated classes skip on the wrong destination: `DatabaseCreationRegularWidthUITests` and `RegularWidthWorkspaceUITests` need an iPad, `DatabaseCreationCompactUITests` an iPhone. A skip is not coverage.
- `AutoFillStoreUITests` is the only device-only class; see below.

### Launch arguments and environment

`KeeForgeUITestCase.setUp` passes `-ui-testing` and seeds fixtures; a class adds the rest in `configureLaunch(app:)`. The app ignores every `UI_TEST_*` variable without `-ui-testing`.

| Setting | Effect |
| --- | --- |
| `-ui-testing` | Reseeds the database list from the fixture payload on every launch, skips the device-owner prompt for reveal/copy, and hides the What's New sheet and AutoFill tip. |
| `UI_TEST_VIEW_MODE` | Starting view of the database root. A database opens on All Entries, but the helpers browse from the group list, so `setUp` sets `groups`. A class testing the real default removes the key (`DefaultViewUITests`). |
| `UI_TEST_DATABASES_JSON`, `UI_TEST_KEYFILE_*` | Written by `setUp`. Override `databaseFixtureName`, `databaseFixtures`, or `keyFileFixtureName` instead of setting them. |
| `UI_TEST_DATABASE_READ_ONLY=1` | Opens the database read-only. |
| `UI_TEST_DEVICE_OWNER_AUTH_PENDING=1` | Re-arms the reveal/copy gate with an authentication that never completes, to assert nothing is disclosed before it succeeds. |
| `UI_TEST_ENABLE_QUICK_LAUNCH=1` | Turns Quick Launch on; never rely on the single-database default. |
| `UI_TEST_SHOW_WHATS_NEW=1`, `UI_TEST_SHOW_AUTOFILL_TIP=1`, `UI_TEST_SHOW_MAC_APP_SUGGESTION=1` | Force a surface that `-ui-testing` otherwise hides. |
| `UI_TEST_LOCAL_SAVE_CONFLICT_COUNT=<n>`, `UI_TEST_LOCAL_SAVE_CONFLICT_DIVERGES_POOL=1` | Inject real save conflicts; see below. |
| `UI_TEST_CLOUD_*_JSON`, `UI_TEST_DROPBOX_PAYLOAD_JSON`, `UI_TEST_WEBDAV_PAYLOAD_JSON` | Seed the mock cloud providers; `CloudSyncBaseUITests` and `WebDAVSyncBaseUITests` build the payloads. |
| `-autofill-store-inspector` | DEBUG only: replaces the app root with the AutoFill store inspector. |
| `-KeeForge.<defaultsKey> <value>` | Overrides a stored preference for one launch. The pair can sit on either side of a bare flag such as `-ui-testing`: argument-domain parsing takes the next token as a flag's value only when it does not start with `-`. |

Opt-in captures are gated on the runner environment: `TEST_RUNNER_APPSTORE_SCREENSHOTS=1` for `AppStoreScreenshots` (it skips otherwise) and `TEST_RUNNER_WHATS_NEW_SCREENSHOTS=1` for `WhatsNewUITests`. Set them as real environment variables on the `xcodebuild` process; a trailing `KEY=value` argument is a build-setting override that never reaches the runner, and the class skips silently.

## Rules for writing and fixing UI tests

### Fix loop

1. Reproduce with the one failing class. Read the assertion and the helper it went through.
2. Export the result bundle's attachments unfiltered; the hierarchy often shows a control the assertion never mentions.
3. Decide: app regression, stale test, or stale project (`xcodegen generate` fixes missing test-file references).
4. Fix the app when behavior or an identifier the product relies on is gone. Fix the test when labels, identifiers, or navigation moved and the app is right.
5. Rerun the same class before moving on.

```bash
ls -td ~/Library/Developer/Xcode/DerivedData/KeeForge-*/Logs/Test/*.xcresult | head -n 1
xcrun xcresulttool get test-results summary --path <xcresult>
xcrun xcresulttool export attachments --path <xcresult> --output-path <fresh-dir>   # then read manifest.json
```

### Shape

- One behavior per method, each from a clean launch. The database list is reseeded, but app defaults persist between tests: set what the test depends on (sort order, Quick Launch).
- Assert on known fixture data through accessibility identifiers, and add an identifier with the feature rather than matching a label (`../KeeForge/Views/AGENTS.md`).
- For a save path, reopen the group or lock and unlock before asserting persisted content.
- Return to a known screen after search, sort, a sheet, or a menu; each replaces the toolbar and navigation controls the next step expects.

### Waiting and hit-testing

- No fixed sleeps. Poll for the element that proves the state changed; use `ciElementTimeout` (15 s) where Cloud's parallel simulators are slow.
- A lazy `List`/`Form` never materializes a row below the fold, so `waitForExistence` on it cannot succeed on a small screen. Anchor "did this screen open" on a navigation bar or toolbar item and `revealElement` anything lower.
- `isHittable` on a zero-frame or off-screen element raises an Objective-C exception that ends the test. On anything mid-transition, check `hasUsableFrame` / `hasOnScreenFrame` first or go through `revealElement`.
- `isHittable` is true for a last row whose center sits under the bottom search bar; `revealElement` then does not scroll and a long press hits the bar. Swipe the list up first and keep the assertion on the context action.
- After a save the workspace is disabled behind `database.saving-overlay` and swallows the next tap. Use `EntryEditUITestCase.waitForAutosaveAttempt()` and its retrying `openAddMenu`, `revealContextMenuButton`, and `revealSwipeDeleteButton`.

### Typing

- `typeText` on an unfocused field fails the test outright and cannot be retried. Use `replaceText(in:with:)`, which scrolls the field clear of the keyboard, re-taps until focus is confirmed, and verifies the value. `XCUIElement.hasFocus` is false for a focused SwiftUI field.
- Database-creation and master-key password fields are typed through `revealPasswordTextField`, `replaceVisiblePasswordFixtureText`, and `dismissKeyboardAfterPasswordFixtureEntry`. Those helpers are for these forms only.
- Unlock with `unlockSuccessfully()`. It retries a wrong-password result, which on parallel simulators usually means the password was typed before the field was ready.
- A create flow that fills a password can raise the system Save Password sheet on a simulator.

### Queries

- SwiftUI folds a row's captions into one label (title with username, a tag with its count). Match with `label CONTAINS` and name the row; "first row" is safe only when the fixture guarantees it.
- Counts and states are accessibility values, not labels: switches (`"1"`/`"0"`; `setSwitch` taps the trailing edge because a switch can report the whole row as its frame), the `entry-detail.history` count, inspector rows. The TOTP code `entry.totp.code` is read from `label`.
- A confirmation dialog's action carries its identifier on two nested buttons; resolve it with `.firstMatch`.
- On iOS 27, buttons inside a `Section` of a SwiftUI `Menu` lose their identifiers while labels survive. Use `menuButton(identifier:label:)`; an identifier-only query never resolves.
- Search results replace the group list in place, and a focused search field covers the root even when empty. Use `searchForEntries(matching:)` and `dismissSearch()`.
- The database root has no navigation-bar title while its large title is on screen. Use `selectDatabaseView(_:)` / `waitForDatabaseView(_:)`, not `app.navigationBars[...]`.
- Database Details is a hub: every control is one push below it and only the hub has Close. `openDatabaseDetailsPage(_:)` before querying, `returnToDatabaseDetailsHub()` before the next page.
- iPadOS can start the split view with its sidebar collapsed. `revealSidebarIfNeeded()` taps the system control only when it offers Show Sidebar; never force a column visibility from a test.
- On the database list a long press opens the context menu and rows move only in Edit mode, so drive a reorder through `database.edit.button`. `DatabaseListUITests` caps its details-reopen test at 120 s so a stall between the two gestures fails fast.

### Injected save conflicts

`UI_TEST_LOCAL_SAVE_CONFLICT_COUNT=<n>` makes `LocalDatabaseSaver` rewrite the file on disk before its hash comparison for the first `n` saves, adding a `UI Test Conflict <n>` entry, so the conflict and any merge run against real divergent bytes. `..._DIVERGES_POOL=1` also grows the binary pool, which makes `KDBXMerger` decline on a fixture with attachments. Set the count to exactly the conflicts wanted: a merge saves again, and a leftover count injects another version into that save.

### Not automatable

- The pasteboard: reading it from the runner raises the system paste prompt. Assert the copy control is offered and tappable.
- QR scanning, and an `otpauth://` link delivered to an already unlocked session (`XCUIApplication.open` relaunches the app). `TOTPEnrollmentDeepLinkUITests` covers the launched-with-URL path only.

## Device AutoFill store suite

`AutoFillStoreUITests` asserts against the real `ASCredentialIdentityStore`. A simulator cannot run it: its enumeration was recorded as empty despite persisted writes (not re-verified; a fresh iOS 27.0 simulator has the provider disabled). It needs a physical iPhone whose store returns readable identities. On iOS 27.0.1 a non-empty store returns private objects without `ASCredentialIdentity` conformance, which the inspector reports as an enumeration error, so every method fails at its first non-zero count there even though publication works. The app's behavior also differs on such a store (a targeted removal clears the whole store), so the union-and-removal method's counts describe a readable store only. It replaces KeeForge's registered database list and clears its credential identities: never run it on a device holding personal vaults.

Preparation, once per install: pair the iPhone for development, install the Debug app (running the class does this), then enable KeeForge under Settings > General > AutoFill & Passwords. To check, launch with `-autofill-store-inspector` and read `autofill-inspector.enabled-state`. Run it with `-destination 'platform=iOS,name=<device>'` and `-parallel-testing-enabled NO`.

- Its two fixtures have disjoint domains and usernames, because the system store can dedup identities that share `(service, user)` across databases regardless of `recordIdentifier`. With overlap the union count is not deterministic.
- The first launch seeds with `-ui-testing`; every later launch in the test omits it so the registry UUIDs and per-database flags survive.
- Store writes are fire-and-forget, so the test pauses briefly before terminating the app. That is the one deliberate sleep; every assertion still polls the inspector.
- An explicitly disabled provider skips. A missing inspector state or an enumeration error fails; it is never read as zero.
- A release result needs all three methods passed with zero skips. A simulator skip, or an enumeration the system cannot return, is a blocked check, not coverage. Do not work around it with private API.
- Still manual: QuickType and Safari filling, the extension's own flows, suggestion cleanup after entry deletion or database removal, and republish when re-enabling the open database.

`AutoFillStoreInspectorSmokeUITests` only checks that the inspector presents; it is safe on any simulator.

## Fixtures

A test selects a bundled fixture by overriding `databaseFixtureName`, or `databaseFixtures` for several databases or a `documents*` disposition. Contents and regeneration are in `../TestFixtures/README.md`.

| Fixture | Password | Used by |
| --- | --- | --- |
| `test.kdbx` | `testpassword123` | Default for every class not listed here |
| `demo.kdbx` | `demo` | `AppStoreScreenshots` |
| `demo-keyfile.kdbx` + `demo-keyfile.key` | `demo` | `KeyFileUnlockUITests` |
| `invalid-xml.keyx` | none | `KeyFileUITests` malformed-key rejection |
| `kitchen-sink.kdbx` | `testpassword123` | `TagBrowserUITests`, `InheritedTagsUITests`, `ViewMenuUITests`, `DefaultViewUITests`, `EntryAttachmentsSmokeUITests`, `SaveConflictMergeDeclineUITests`, `ProtectedCustomFieldUITests`, `ProtectedCustomFieldEditorAuthUITests`, `EntryCustomIconPickerUITests` |
| `autofill-union.kdbx` | `testpassword123` | `TOTPSmokeUITests`, `TOTPEnrollmentUITests`, `TOTPEnrollmentDeepLinkUITests` |
| `autofill-store-alpha.kdbx`, `autofill-store-bravo.kdbx` | `testpassword123` | `AutoFillStoreUITests` |
| `compatibility/legacy-kdbx31.kdbx` | `testpassword123` | `UnlockedDatabaseBrowseAndDetailUITests` read-only KDBX 3.1 case |

- Only these are bundled. `test`, `demo`, `demo-keyfile` (database and key), and `kitchen-sink` come from the `UITestFixtures` template in `project.yml`, shared with `KeeForgeMacUITests`; the rest are this target's extras. To use another fixture, add it to the fitting list and run `xcodegen generate`.
- `test.kdbx` has only groups at its root, so a test enters `Social` or `Work` before opening an entry.

## Base-class helpers

Extend a base class instead of repeating launch or unlock code, and promote a repeated flow into it.

- `KeeForgeUITestCase`: launch, fixtures, unlock, search, view menu, Database Details, scrolling, typing. Start a test with `unlockSuccessfully()`.
- `UnlockedDatabaseUITestCase` for browse and detail (`openEntry(named:inGroup:)`, `searchResult(named:)`); `EntryEditUITestCase` for create, edit, delete, and context menus.
- `EntryEditSmokeUITests.testAddedURLIsSavedAndShownOnTheEntry` exercises a second URL added in the editor and its detail presentation without duplicate custom-field text.
- `UnlockedDatabaseBrowseAndDetailUITests` checks that compact entry detail omits `lock.button`, then returns to its list and locks. `TagBrowserUITests` covers the longer return path from a tagged entry to manual lock.
- `EntrySelectionMoveUITests` covers selecting two group entries, Cancel, and moving through the shared picker. Cross-group, search, and tag selection use the same session state and need separate UI coverage.
- Area bases: `DatabaseCreationUITestCase`, `SaveConflictMergeUITestCase`, `AppSettingsUITestCase`, `TOTPEnrollmentUITestCase`, `CloudSyncBaseUITests`, `WebDAVSyncBaseUITests`.
