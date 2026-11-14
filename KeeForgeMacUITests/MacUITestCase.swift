import XCTest

/// Base class for the macOS smoke suite. Mirrors `KeeForgeUITestCase`'s
/// fixture-injection launch environment (`UI_TEST_DATABASES_JSON`, key file
/// seeding, `-ui-testing`) but exposes Mac-flavored helpers: keyboard
/// shortcuts (`typeKey`), right-click context menus, and click-based
/// navigation instead of swipe-based scrolling.
@MainActor
class MacUITestCase: XCTestCase {
    static let uiTestDatabasesJSONEnv = "UI_TEST_DATABASES_JSON"
    private static let uiTestKeyFileBase64Env = "UI_TEST_KEYFILE_BASE64"
    private static let uiTestKeyFileFilenameEnv = "UI_TEST_KEYFILE_FILENAME"

    static let fixturePassword = "testpassword123"

    struct DatabaseFixture {
        let resourceName: String
        let resourceExtension: String
        let injectedFilename: String

        init(resourceName: String, resourceExtension: String = "kdbx", injectedFilename: String) {
            self.resourceName = resourceName
            self.resourceExtension = resourceExtension
            self.injectedFilename = injectedFilename
        }
    }

    var app: XCUIApplication!

    /// Override in subclasses to use different database fixtures.
    var databaseFixtures: [DatabaseFixture] {
        [DatabaseFixture(resourceName: "test", injectedFilename: "test.kdbx")]
    }

    override func setUp() async throws {
        continueAfterFailure = false

        app = XCUIApplication()
        // -ApplePersistenceIgnoreState: macOS state restoration can restore a
        // "zero windows" session (e.g. after a killed run), leaving the app
        // with no window at all; every UI test needs a fresh window.
        // Auto-unlock would raise a Touch ID prompt XCUITest cannot answer.
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-KeeForge.autoUnlockWithFaceID", "NO",
            "-ui-testing",
        ]

        let payloads = try databaseFixtures.map { fixture -> [String: String] in
            let data = try fixtureData(
                resourceName: fixture.resourceName,
                resourceExtension: fixture.resourceExtension
            )
            return [
                "filename": fixture.injectedFilename,
                "base64": data.base64EncodedString(),
            ]
        }
        let payloadData = try JSONSerialization.data(withJSONObject: payloads, options: [])
        app.launchEnvironment[Self.uiTestDatabasesJSONEnv] = String(decoding: payloadData, as: UTF8.self)

        try configureLaunch(app: app)
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        try await super.tearDown()
    }

    /// Override to add launch environment (e.g. WebDAV payloads) before launch.
    func configureLaunch(app: XCUIApplication) throws {}

    func fixtureData(resourceName: String, resourceExtension: String) throws -> Data {
        guard let fixtureURL = Bundle(for: MacUITestCase.self).url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            throw NSError(
                domain: "KeeForgeMacUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(resourceName).\(resourceExtension) fixture in test bundle"]
            )
        }
        return try Data(contentsOf: fixtureURL)
    }

    // MARK: - Windows

    /// The Databases window, which holds the database list and nothing else.
    var databasesWindow: XCUIElement {
        app.windows.matching(identifier: "databases").firstMatch
    }

    /// Every open database window (`database.<UUID>`, titled with the database name).
    var databaseWindows: XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'database.'"))
    }

    /// The open database window for `name`. The accessibility title adds the
    /// unlocked window's subtitle after an en dash.
    func databaseWindow(named name: String) -> XCUIElement {
        databaseWindows.matching(NSPredicate(format: "title == %@ OR title BEGINSWITH %@", name, "\(name) – ")).firstMatch
    }

    /// Chooses a menu-bar command by its titles.
    func chooseMenuItem(_ item: String, inMenu menu: String, file: StaticString = #filePath, line: UInt = #line) {
        let menuBarItem = app.menuBars.menuBarItems[menu].firstMatch
        XCTAssertTrue(menuBarItem.waitForExistence(timeout: 5), "No '\(menu)' menu", file: file, line: line)
        menuBarItem.click()
        let menuItem = menuBarItem.menuItems[item].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "No '\(item)' item in '\(menu)'", file: file, line: line)
        menuItem.click()
    }

    /// Window > Databases, which fronts the Databases window.
    func showDatabasesWindow(file: StaticString = #filePath, line: UInt = #line) {
        chooseMenuItem("Databases", inMenu: "Window", file: file, line: line)
        XCTAssertTrue(databasesWindow.waitForExistence(timeout: 10), "Window > Databases did not show the Databases window",
            file: file, line: line)
    }

    /// The database window of a test that opens a single database.
    var databaseWindow: XCUIElement {
        databaseWindows.firstMatch
    }

    // MARK: - Database list

    /// A Databases-window row showing `text`. Rows are list cells, not
    /// buttons, and SwiftUI copies the identifier onto the row's text.
    func databaseRow(containing text: String) -> XCUIElement {
        databaseRowQuery(containing: text).firstMatch
    }

    private func databaseRowQuery(containing text: String?) -> XCUIElementQuery {
        let rows = databasesWindow.descendants(matching: .any)
        guard let text else { return rows.matching(identifier: "database.row") }
        return rows.matching(NSPredicate(
            format: "identifier == 'database.row' AND (label CONTAINS[c] %@ OR value CONTAINS[c] %@)", text, text
        ))
    }

    /// Selects a Databases-window row with a single click, which never opens
    /// it, and waits until the Open button reflects the selection.
    @discardableResult
    func selectDatabaseRow(
        containing text: String? = nil,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        // The row's name text, not its icon, which shares the identifier.
        let query = databaseRowQuery(containing: text).matching(NSPredicate(format: "elementType == %d",
            XCUIElement.ElementType.staticText.rawValue))
        let open = databasesWindow.buttons["databases.open"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let row = query.allElementsBoundByIndex.first(where: {
                $0.exists && $0.isHittable && $0.frame.height > 1
            }) {
                row.click()
                let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
                if XCTWaiter.wait(for: [selected], timeout: 2) == .completed { return row }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        XCTFail("Database list did not select a row for '\(text ?? "any database")'", file: file, line: line)
        return nil
    }

    /// The Settings window. It can never become main, so it reports as a dialog.
    var settingsWindow: XCUIElement {
        app.dialogs["settings"].firstMatch
    }

    /// Opens a database from the Databases window (select, then Open) and
    /// returns its window once it shows the unlock screen.
    @discardableResult
    func openDatabase(
        named name: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let window = databaseWindow(named: name)
        // An open database window can cover the Databases window's rows.
        if databaseWindows.count > 0 { showDatabasesWindow(file: file, line: line) }
        guard selectDatabaseRow(containing: name, timeout: timeout, file: file, line: line) != nil else { return window }
        let open = databasesWindow.buttons["databases.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "The Databases window has no Open button", file: file, line: line)
        waitUntilEnabled(open)
        open.click()
        XCTAssertTrue(window.waitForExistence(timeout: timeout), "No window opened for '\(name)'", file: file, line: line)
        XCTAssertTrue(
            window.secureTextFields["unlock.password.field"].waitForExistence(timeout: timeout),
            "The window for '\(name)' did not show the unlock screen",
            file: file,
            line: line
        )
        return window
    }

    /// Opens the first listed database unless a database window is already
    /// on its unlock screen.
    @discardableResult
    func openFirstDatabaseFromListIfNeeded(
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let passwordField = databaseWindow.secureTextFields["unlock.password.field"]
        if passwordField.waitForExistence(timeout: 2) {
            return true
        }
        guard selectDatabaseRow(timeout: timeout, file: file, line: line) != nil else { return false }
        let open = databasesWindow.buttons["databases.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "The Databases window has no Open button", file: file, line: line)
        waitUntilEnabled(open)
        open.click()
        XCTAssertTrue(
            passwordField.waitForExistence(timeout: timeout),
            "Password field did not appear after opening the database",
            file: file,
            line: line
        )
        return true
    }

    /// Keyboard focus is app-wide, so it also proves which window is key.
    func waitForKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.value(forKey: "hasKeyboardFocus") as? Bool != true {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        _ = XCTWaiter.wait(for: [enabled], timeout: timeout)
    }

    // MARK: - Unlock

    /// Unlocks `window`, or the only database window, opening the first
    /// listed database when none is open.
    func unlock(
        password: String,
        in window: XCUIElement? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if window == nil { openFirstDatabaseFromListIfNeeded(file: file, line: line) }
        let window = window ?? databaseWindow

        let passwordField = window.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15), "Password field did not appear", file: file, line: line)
        passwordField.click()
        passwordField.typeText(password)

        let unlockButton = window.buttons["unlock.button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5), "Unlock button did not appear", file: file, line: line)
        unlockButton.click()
    }

    func unlockSuccessfully(in window: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
        unlock(password: Self.fixturePassword, in: window, file: file, line: line)
        waitForVaultToUnlock(in: window ?? databaseWindow, file: file, line: line)
    }

    @discardableResult
    func waitForVaultToUnlock(
        in window: XCUIElement? = nil,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let window = window ?? databaseWindow
        // The sidebar outline's group rows exist only in an unlocked workspace;
        // toolbar buttons can collapse into the overflow, so they prove nothing.
        let groupLink = window.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        let errorLabel = window.staticTexts["unlock.error.label"]
        let deadline = Date().addingTimeInterval(timeout)
        var lastErrorMessage: String?

        repeat {
            if groupLink.exists {
                return true
            }
            if errorLabel.exists {
                let message = errorLabel.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty {
                    lastErrorMessage = message
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        if let lastErrorMessage {
            XCTFail("Vault did not unlock. Last error: \(lastErrorMessage)", file: file, line: line)
        } else {
            XCTFail("Vault did not unlock within \(timeout) seconds", file: file, line: line)
        }
        return false
    }

    /// Whether `window` shows its database's unlock screen with no sidebar.
    /// `waitForVaultToUnlock` finds the same rows, so their absence means something.
    func waitForLockedState(in window: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let passwordField = window.secureTextFields["unlock.password.field"]
        let groupLink = window.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        let outline = window.outlines[Self.sidebarOutlineIdentifier]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if passwordField.exists, !groupLink.exists, !outline.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    // MARK: - Navigation

    static let sidebarOutlineIdentifier = "sidebar.outline"

    /// Clicks the named group's sidebar row, the Recycle Bin's included.
    func openGroup(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        clickRow(identifier: "group.navlink", containing: name, rowKind: "Group", file: file, line: line)
    }

    /// Clicks the named entry row; the detail pane shows the entry.
    func openEntry(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        clickRow(identifier: "entry.navlink", containing: name, rowKind: "Entry", file: file, line: line)
    }

    /// Clicks the first HITTABLE row matching the identifier and visible text.
    ///
    /// Not restricted to `.button`: a sidebar row's identifier sits on its title
    /// text in the AppKit outline, because XCUITest drops a table cell's own
    /// identifier, and the content columns are native `List(selection:)` whose
    /// text lands in `value` rather than `label`, so the predicate accepts either. The hittability and height
    /// filters skip the zero-sized wrappers and stale navigation layers SwiftUI
    /// copies row identifiers onto (XCUITest fails with "Unable to find hit point").
    private func clickRow(
        identifier: String,
        containing name: String,
        rowKind: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND (label CONTAINS[c] %@ OR value CONTAINS[c] %@)",
                identifier, name, name
            )
        )

        let deadline = Date().addingTimeInterval(15)
        repeat {
            if let row = query.allElementsBoundByIndex.first(where: {
                $0.exists && $0.isHittable && $0.frame.height > 1
            }) {
                row.click()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTFail("\(rowKind) '\(name)' was not clickable within 15 seconds", file: file, line: line)
    }

    /// Any element carrying a vault row identifier, regardless of element type
    /// (see `clickRow` for why the type is not pinned).
    func rowQuery(identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    /// The visible text of a SwiftUI element. Most `Text` on macOS reports
    /// through the AppKit `value` attribute and leaves `label` empty, so
    /// reading only one of the two misses half the hierarchy. Returns "" for an
    /// element that has gone away, which a rebuilding SwiftUI view does between
    /// a query and the read that follows it.
    func displayText(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        let label = element.label
        if label.isEmpty == false { return label }
        return element.value as? String ?? ""
    }

    /// Polls until an element carrying `identifier` reports `expected` as its
    /// visible text. Re-queries every pass rather than holding one element, so a
    /// view that rebuilds mid-wait cannot fail the read.
    func waitForDisplayText(
        _ expected: String,
        identifier: String,
        timeout: TimeInterval = 15
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = rowQuery(identifier: identifier).allElementsBoundByIndex
            if matches.contains(where: { displayText(of: $0) == expected }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    /// Clicks the first hittable row carrying `identifier`, whatever it says.
    /// The name-matching `clickRow` cannot be used where the point of the test
    /// is that it does not care which row it lands on — only that the next
    /// keystroke moves off it.
    @discardableResult
    func clickFirstRow(
        identifier: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let row = rowQuery(identifier: identifier).allElementsBoundByIndex.first(where: {
                $0.exists && $0.isHittable && $0.frame.height > 1
            }) {
                row.click()
                return displayText(of: row)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTFail("No hittable '\(identifier)' row within \(Int(timeout)) seconds", file: file, line: line)
        return ""
    }

    /// The entry title the detail column is currently showing, or "" if none.
    /// An instantaneous read — the detail column takes a moment to render after
    /// a selection changes, so a test that has just clicked wants
    /// `waitForAnyDetailTitle()` instead.
    func detailTitle() -> String {
        let matches = rowQuery(identifier: "entry-detail.title").allElementsBoundByIndex
        return matches.map(displayText(of:)).first { $0.isEmpty == false } ?? ""
    }

    /// Polls until the detail column shows any entry, and returns its title.
    /// Returns "" if none appears within the timeout.
    func waitForAnyDetailTitle(timeout: TimeInterval = 15) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let current = detailTitle()
            if current.isEmpty == false { return current }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return ""
    }

    /// Polls until the detail column shows something other than `previous`.
    func waitForDetailTitleToChange(from previous: String, timeout: TimeInterval = 15) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let current = detailTitle()
            if current.isEmpty == false, current != previous {
                return current
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    /// Reads the `results:N` overlay the search screen renders under
    /// `-ui-testing`. Returns -1 if it never appears.
    func searchResultCount(timeout: TimeInterval = 20) -> Int {
        let overlay = app.staticTexts["search.results.count"]
        guard overlay.waitForExistence(timeout: timeout) else { return -1 }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let text = displayText(of: overlay)
            if text.hasPrefix("results:"), let value = Int(text.dropFirst("results:".count)) {
                if value > 0 { return value }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return 0
    }

    // MARK: - Menu commands

    func typeCommandShortcut(_ key: String, modifiers: XCUIElement.KeyModifierFlags = [.command]) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    // MARK: - Settings window

    /// Selects a tab in the Settings window by its visible name.
    ///
    /// The retained AppKit Settings window keeps its tab while closed. A test
    /// that needs a specific tab's controls selects it explicitly rather than
    /// assuming the first one. The `settings.tab.*` identifiers sit on the tab
    /// *content*, not on the control that switches tabs, so the visible name is
    /// the only handle — matched across element types and both text attributes,
    /// like the vault rows.
    @discardableResult
    func selectSettingsTab(
        named name: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", name, name)
        )

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let tab = query.allElementsBoundByIndex.first(where: {
                $0.exists && $0.isHittable && $0.frame.height > 1
            }) {
                tab.click()
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTFail("Settings tab '\(name)' was not clickable within \(Int(timeout)) seconds", file: file, line: line)
        return false
    }

    // MARK: - Toolbar

    /// Clicks a toolbar control, expanding the macOS "more toolbar items"
    /// overflow popup when the control collapsed into it (overflow entries
    /// surface as menu items matched by label, not identifier).
    func clickToolbarButton(
        identifier: String,
        overflowLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let direct = app.buttons[identifier].firstMatch
        if direct.waitForExistence(timeout: 3), direct.isHittable {
            direct.click()
            return
        }

        let overflow = app.popUpButtons["more toolbar items"].firstMatch
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 10),
            "Neither toolbar button '\(identifier)' nor the toolbar overflow was found",
            file: file,
            line: line
        )
        overflow.click()

        let overflowItem = app.menuItems[overflowLabel].firstMatch
        XCTAssertTrue(
            overflowItem.waitForExistence(timeout: 10),
            "Toolbar overflow did not contain '\(overflowLabel)'",
            file: file,
            line: line
        )
        overflowItem.click()
    }
}
