# KeeForgeMacUITests

**Scope:** XCUITest smoke suite for the native macOS app (scheme `KeeForgeMac`). It is a thin layer by design; see "macOS tests" in `../AGENTS.md`. The fix workflow, launch environment, and fixtures are shared with `../KeeForgeUITests/AGENTS.md`.

## Running

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:KeeForgeMacUITests/MacSmokeUITests
```

- The suite runs on the Studio only when explicitly selected; Xcode Cloud does not run it. It drives real windows and takes screen and keyboard focus, so it needs an unlocked, active login session; with the screen locked it fails with "Failed to activate application (Running Background)".
- It needs Automation Mode. If `automationmodetool` (no arguments, read-only) says enabling it requires authentication, the runner prompts and, unattended, fails with "Timed out while enabling automation mode" after running zero tests. Zero tests run is a failure, not a pass.
- `MacSmokeUITests` is the required local release smoke (`prepare-release` skill).
- Split geometry autosaves into the app's defaults under `MacDatabaseWorkspace.<database UUID>`. Fixture databases get new UUIDs on each seeded launch, so no test inherits a collapsed sidebar from an earlier run; unit tests hosted by the app write none.
- `MacScreenshotAuditUITests` skips unless `TEST_RUNNER_SCREENSHOT_AUDIT=1` is set; `TEST_RUNNER_SCREENSHOT_AUDIT_DARK=1` switches its captures to dark. Both must be real environment variables on the `xcodebuild` process: a trailing `KEY=value` argument is a build-setting override that never reaches the runner, and the class skips silently.

- `MacAppStoreScreenshots` skips unless `TEST_RUNNER_APPSTORE_SCREENSHOTS=1` is set. It captures the Mac App Store screenshots from `demo.kdbx` in a 1440x900 pt database window, sized with `-ui-testing-database-window-size` because XCUITest corner drags do not resize windows on macOS 27.
- Several database windows at once (key-window routing of Find, Lock and menu commands, also with Settings key; fronting a minimized window from the Databases window; the close prompt on one window; the Window menu; the last window closing): `MacWindowLifecycleUITests`. Routing and restoration decisions stay unit-tested in `MacDatabaseCommandTargetResolverTests` and `MacWindowCoordinatorTests`.

- Passphrase generator copy and Use controls: the generator case in `MacSmokeUITests`. Generation and saved options are covered headlessly by `PasswordGeneratorTests` and `SettingsServiceTests`.
- Custom-icon management: `MacCustomIconManagementUITests` exercises rename, cancelled deletion, and confirmed deletion from the entry picker.
- Restore entry/group context actions and split-view refresh: the restore cases in `MacSmokeUITests`. Shared policy and persistence remain unit-tested.
- Sidebar: `testSidebarShowsItsSectionsAndAllEntriesListsEveryGroup` (Library, Groups and Tags headers, the Recycle Bin as the last row with no header, All Entries listing several groups; it alone launches `kitchen-sink.kdbx`), `testDownArrowMovesTheSidebarGroupSelection` (arrows move the selection, Left and Right fold and unfold), and the restore cases (group-row menu items). Which rows appear, menu gates and selection sync stay in `MacSidebarSnapshotTests` and `MacSidebarViewControllerTests`. The app staying open after its last window closes is `MacMainMenuTests`.

## Invariants

### Launch

- `-key value` argument pairs can sit on either side of the bare `-ui-testing` flag: argument-domain parsing takes the next token as a flag's value only when it does not start with `-`.
- `-ApplePersistenceIgnoreState YES` stays in the base launch. Without it state restoration can restore a session with no windows and no main window ever appears.
- Never pass `-AppleLanguages` / `-AppleLocale` on macOS: on macOS 27.2 the app then launches with no window at all (cause unknown), and every query fails as "Database list did not appear". The Mac suite relies on the session's English locale.
- To capture the app's own windows, launch with `-KeeForge.blockScreenCapture NO`, placed as above. The app excludes its windows from capture by default, so a capture is blank or shows whatever is behind the app.
- Under `-ui-testing`, revealing or copying a protected value never asks for Touch ID or the login password: `BiometricService.canAuthenticateDeviceOwner` reports no device-owner authentication, so the gate is skipped, because XCUITest cannot answer the system prompt. A reveal that shows nothing in a test is therefore never a pending prompt; look for a click that missed. A boundary test launches with `UI_TEST_DEVICE_OWNER_AUTH_PENDING=1`, which re-arms the gate with an authentication that never completes. Without it, immediate disclosure reads as a leak.
- `MacScreenshotAuditUITests` opens database windows at 1080×700 pt content, then relaunches with the 900×620 minimum for its minimum-width capture and asserts the resulting frame. Corner drags do not resize windows on macOS 27.
- Under `-ui-testing` the app restores no windows on launch and records no window topology, so one test's windows never reappear in the next (`MacWindowLaunchOptions`). Each database window it opens starts at 1080 x 700 pt content, or at the size given by `-ui-testing-database-window-size <width>x<height>` (for example `1440x900`); a malformed value is ignored. A second window cascades from the frontmost one.

### Queries

- AppKit owns the Databases window (`databases`), one window per open database (`database.<UUID>`, titled with the database name; its accessibility title adds the unlocked subtitle after an en dash), the menus (Window ▸ Databases shows the Databases window; the Window menu lists each database window by name), and the retained Settings window (`settings`). Each database window's root hosting controller remains mounted; unlocked content embeds an AppKit three-item split view whose columns each host SwiftUI. The unlocked window's toolbar is a native `NSToolbar` (`MacWorkspaceToolbar`) with an `NSSearchToolbarItem`; the unlock screen keeps the root's bridged SwiftUI toolbar. AppKit observation sets the title.

- The three SwiftUI column roots share a stable outer workspace presentation host; column revision keys must never replace it. Keep UI coverage for keyboard and double-click browsing, edit/move/delete/new-group sheets through row revisions, search and Find, repeated lock/unlock width restoration, launch/enrollment presentations, and saving/conflict banners. The split dividers are native AppKit splitters; the existing `app.splitters` query remains valid. The native toolbar exposes item identifiers on its controls: buttons still match `app.buttons[identifier]` (each item's view carries its item identifier), the search field is `app.searchFields.firstMatch`, and Command-F focuses it. Add and Sort are pull-down pop-up buttons. Verify View → Show Sidebar, widths after collapse/resize and repeated lock/unlock, and the toolbar's entry Edit action, including delete-from-editor completion, across hosting boundaries.

- Scope queries to a window. `MacUITestCase.databasesWindow` is the Databases window, `databaseWindow(named:)` one database's window and `databaseWindow` the only one; never use `windows.firstMatch` or the largest window. The database list exists only in the Databases window, so a launcher row never proves a database locked or opened: check the database window (`waitForLockedState(in:)`, `waitForVaultToUnlock(in:)`).
- Database rows (`database.row`) are `List(selection:)` cells, not buttons, and SwiftUI copies the identifier onto their text. A single click selects; double-click, Return, the `databases.open` button or the row's Open item opens or fronts the database's window. `selectDatabaseRow(containing:)` selects, `openDatabase(named:)` selects and presses Open and returns the database window on its unlock screen. The Databases window's bottom bar holds `databases.create-new`, `databases.add-existing`, the `databases.connect-server` menu (items `database.add.webdav`, `database.add.ftp`) and `databases.open`; the empty state keeps `database.empty.create` and `database.empty.add`.
- Escape or Choose Different File on a database window's unlock screen closes that window and shows the Databases window. Launch presentations (transition notice, What's New) and the verification-code destination prompt (`databases.enrollment-destination.row`, `databases.enrollment-destination.cancel`) appear on the Databases window. Database menu commands are disabled while the Databases window is key; with Settings key they act on the last focused database window.
- Front a particular window with its Window-menu item (`chooseMenuItem(_:inMenu:)`, `showDatabasesWindow()`): cascaded windows overlap, so a click on the one behind can land on the one in front. Keyboard focus is app-wide, so `waitForKeyboardFocus` on a control also proves its window is key.
- Vault rows are not buttons, although the same `group.navlink` / `entry.navlink` identifiers are buttons on iOS (`../KeeForge/Views/AGENTS.md`). Never query them through `app.buttons`. Use `MacUITestCase.openGroup`, `openEntry`, `clickFirstRow`, or `rowQuery(identifier:)`.
- The sidebar is an AppKit outline, `window.outlines["sidebar.outline"]`. XCUITest drops a table cell's own identifier, so each row's identifier (`group.navlink`, `sidebar.collection.allEntries`, `sidebar.collection.verificationCodes`, `tag-list.row.*`) sits on its title `StaticText`, whose `value` is the title; the cell carries the title as its label. Section headers are plain `StaticText`s. Group-row menu items keep their `group-row.*` identifiers, which `NSMenuItem.identifier` exposes. A tall sidebar opens scrolled to the top.
- `waitForVaultToUnlock` waits for a `group.navlink` row in the window (toolbar buttons can collapse into the overflow and prove nothing); `waitForLockedState` needs the unlock field with neither those rows nor the outline, which is meaningful only because unlock detection finds the same rows.
- Most SwiftUI `Text` reports through the AppKit `value` attribute with an empty `label`. Read text with `displayText(of:)` and wait with `waitForDisplayText(_:identifier:)`, which re-queries every pass: reading a property from an element a rebuilding view has replaced fails the test.
- SwiftUI copies row identifiers onto zero-sized wrappers and stale navigation layers. Click only a hittable match with a real height, as the row helpers do.
- Match a context-menu item as an enabled, hittable `menuItems` element, never `firstMatch` on its title. The menu bar holds disabled items with the same titles; `firstMatch` picks one, clicks nothing, and leaves the context menu open and the window modal.
- A SwiftUI `Toggle` in a form is a switch, not a checkbox: query `app.switches` and read its state as a number (`value as? Int`), not the string iOS reports.
- Scroll the scroll view that contains the target. `app.scrollViews.firstMatch` is usually the sidebar or a list, not the editor or entry detail, and scrolling it leaves the target where it was.
- A control touching the window's bottom edge reports hittable, but a click there misses it. Scroll it clear of the edge first.
- XCUITest drags do not move split-view dividers on macOS 27, so resizing a column is a manual check. Unit tests cover native split-item constraints and collapse; autosave restoration requires the repeated-lock/unlock UI test and manual divider resizing.
- Toolbar buttons, `lock.button` included, can collapse into the "more toolbar items" overflow, where they are menu items matched by label. Use `clickToolbarButton(identifier:overflowLabel:)`, and detect the unlocked state from vault rows as `waitForVaultToUnlock` does.
- Settings can never become main, so XCUITest reports it as a dialog: query it as `MacUITestCase.settingsWindow` (`app.dialogs["settings"]`), never `app.windows`.
- The retained AppKit Settings window reopens on the tab used last in this process; a fresh root starts on Security. Select the tab with `selectSettingsTab(named:)`; the `settings.tab.*` identifiers sit on tab content, not on the switching control.
- Closing a database window locks and retires its session (`MacWindowCloseGuard`), even with other windows open, and the app keeps running with no window. A test pressing Command-W in a database window must expect the window to close and its database to lock; the Databases window reopens it in a new, locked window. Removing a database from the list closes its window.

### Screenshot audit

- Captures come from each window's own content through ScreenCaptureKit. `XCUIElement.screenshot()` and `XCUIApplication.screenshot()` capture the screen region and return whatever is in front.
- The runner (`KeeForgeMacUITests-Runner`) needs Screen Recording permission, under System Settings > Privacy & Security > Screen & System Audio Recording.
- A capture that cannot be taken is listed in the `00-skipped-captures` attachment instead of attaching the wrong pixels. A short export is a harness problem, not a missing screen.
- Captures are forced light or dark through `-KeeForge.appearanceMode`; the host appearance does not decide.
- `testCaptureScreens` also captures a selected Library row (`03b`), a group's context menu (`08d`; ScreenCaptureKit finds no window record for the menu, so it is listed as skipped), the Recycle Bin its delete creates (`08e`), the hidden sidebar (`08f`), and relaunches read-only (`UI_TEST_DATABASE_READ_ONLY`) for `10-minimum-width`, so the sidebar's status card shows. `UI_TEST_HIDE_SEARCH_RESULTS_COUNT=1` keeps the `results:N` test overlay out of them, while other suites still read `search.results.count`.

## Fixtures

The bundle holds only the shared `UITestFixtures` set listed in `../KeeForgeUITests/AGENTS.md`; override `databaseFixtures` to choose. `kitchen-sink.kdbx` is the only one whose sidebar has a Tags section and, before any delete, a Recycle Bin.

## See also

- `../AGENTS.md`: "macOS tests", where Mac behavior gets tested
- `../TestFixtures/README.md`: fixture contents and passwords
