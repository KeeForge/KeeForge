import XCTest

/// Base class for the macOS smoke suite. Mirrors `KeeForgeUITestCase`'s
/// fixture-injection launch environment (`UI_TEST_DATABASES_JSON`, key file
/// seeding, `-ui-testing`) but exposes Mac-flavored helpers: keyboard
/// shortcuts (`typeKey`), right-click context menus, and click-based
/// navigation instead of swipe-based scrolling.
@MainActor
class MacUITestCase: XCTestCase {
    private static let uiTestDBFilenameEnv = "UI_TEST_DB_FILENAME"
    private static let uiTestDatabasesJSONEnv = "UI_TEST_DATABASES_JSON"
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
        // with no main window at all; every UI test needs a fresh window.
        //
        // Order matters: NSUserDefaults argument parsing pairs `-key value`,
        // so the bare `-ui-testing` flag must come LAST — placed before the
        // pair it would swallow `-ApplePersistenceIgnoreState` as its value
        // and state restoration would run anyway.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-ui-testing"]

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

        if let firstFixture = databaseFixtures.first {
            app.launchEnvironment[Self.uiTestDBFilenameEnv] = firstFixture.injectedFilename
        }

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

    // MARK: - Database list

    func databaseRow(containing text: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == 'database.row' AND label CONTAINS[c] %@", text)
        ).firstMatch
    }

    @discardableResult
    func openFirstDatabaseFromListIfNeeded(
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let passwordField = app.secureTextFields["unlock.password.field"]
        if passwordField.waitForExistence(timeout: 2) {
            return true
        }

        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(
            databaseRow.waitForExistence(timeout: timeout),
            "Database list did not appear",
            file: file,
            line: line
        )
        databaseRow.click()

        XCTAssertTrue(
            passwordField.waitForExistence(timeout: timeout),
            "Password field did not appear after opening the database",
            file: file,
            line: line
        )
        return true
    }

    // MARK: - Unlock

    func unlock(password: String, file: StaticString = #filePath, line: UInt = #line) {
        openFirstDatabaseFromListIfNeeded(file: file, line: line)

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15), "Password field did not appear", file: file, line: line)
        passwordField.click()
        passwordField.typeText(password)

        let unlockButton = app.buttons["unlock.button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5), "Unlock button did not appear", file: file, line: line)
        unlockButton.click()
    }

    func unlockSuccessfully(file: StaticString = #filePath, line: UInt = #line) {
        unlock(password: Self.fixturePassword, file: file, line: line)
        waitForVaultToUnlock(file: file, line: line)
    }

    @discardableResult
    func waitForVaultToUnlock(
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        // On macOS the custom toolbar buttons (including lock.button) can
        // collapse into the "more toolbar items" overflow, so unlocked state
        // is detected via vault content (the root group list) instead.
        let groupLink = app.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        let entryLink = app.descendants(matching: .any).matching(identifier: "entry.navlink").firstMatch
        let lockButton = app.buttons["lock.button"].firstMatch
        let errorLabel = app.staticTexts["unlock.error.label"]
        let deadline = Date().addingTimeInterval(timeout)
        var lastErrorMessage: String?

        repeat {
            if groupLink.exists || entryLink.exists || lockButton.exists {
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

    @discardableResult
    func waitForLockedState(timeout: TimeInterval = 15) -> Bool {
        let passwordField = app.secureTextFields["unlock.password.field"]
        let databaseRow = app.buttons["database.row"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if passwordField.exists || databaseRow.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return passwordField.exists || databaseRow.exists
    }

    // MARK: - Navigation

    /// Clicks into the named fixture group in the sidebar group list.
    func openGroup(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        clickRow(identifier: "group.navlink", containing: name, rowKind: "Group", file: file, line: line)
    }

    /// Clicks the named entry row; the detail pane shows the entry.
    func openEntry(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        clickRow(identifier: "entry.navlink", containing: name, rowKind: "Entry", file: file, line: line)
    }

    /// Clicks the first HITTABLE row matching the identifier and visible text.
    ///
    /// Deliberately NOT restricted to `.button`: the macOS vault columns are
    /// native `List(selection:)`, so their rows surface as `Outline`/`Table`
    /// cells whose text is a `StaticText` descendant, not as buttons. That text
    /// also lands in the AppKit `value` attribute rather than `label` for most
    /// SwiftUI `Text`, so the predicate has to accept either. The hittability
    /// and height filters stay — SwiftUI propagates row identifiers onto
    /// zero-sized wrapper elements and keeps stale navigation layers in the
    /// hierarchy, neither of which can be clicked (XCUITest fails with "Unable
    /// to find hit point").
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

    // MARK: - Menu commands

    func typeCommandShortcut(_ key: String, modifiers: XCUIElement.KeyModifierFlags = [.command]) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    // MARK: - Settings window

    /// Selects a tab in the Settings window by its visible name.
    ///
    /// The `Settings { }` scene restores whichever tab was open last through
    /// `com_apple_SwiftUI_Settings_selectedTabIndex`, which persists in the
    /// app's own preferences and therefore survives a UI-test launch. A test
    /// that needs a specific tab's controls has to select the tab rather than
    /// assume the first one. The `settings.tab.*` identifiers sit on the tab
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
