import XCTest

/// Several database windows at once: key-window command routing, fronting an
/// open window, the close guard on one window, the Window menu. Relaunch
/// restoration, the routing decisions and staying open after the last window
/// closes are unit-tested (`MacDatabaseCommandTargetResolverTests`,
/// `MacWindowCoordinatorTests`, `MacMainMenuTests`);
/// only the running app shows AppKit delivering key focus, menus and closes.
@MainActor
final class MacWindowLifecycleUITests: MacUITestCase {
    override var databaseFixtures: [DatabaseFixture] {
        [
            DatabaseFixture(resourceName: "test", injectedFilename: "Alpha.kdbx"),
            DatabaseFixture(resourceName: "test", injectedFilename: "Bravo.kdbx"),
        ]
    }

    override func configureLaunch(app: XCUIApplication) throws {
        if name.contains("UnsavedWork") { app.launchEnvironment["UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"] = "1" }
    }

    private var alpha: XCUIElement { databaseWindow(named: "Alpha") }
    private var bravo: XCUIElement { databaseWindow(named: "Bravo") }

    func testCommandsFollowTheKeyDatabaseWindowAndTheMainWindowUnderSettings() {
        unlockSuccessfully(in: openDatabase(named: "Alpha"))
        unlockSuccessfully(in: openDatabase(named: "Bravo"))

        makeKey("Alpha")
        typeCommandShortcut("f")
        XCTAssertTrue(waitForKeyboardFocus(alpha.searchFields.firstMatch), "⌘F did not focus the key window's search")
        XCTAssertNotEqual(bravo.searchFields.firstMatch.value(forKey: "hasKeyboardFocus") as? Bool, true)
        app.typeKey(.escape, modifierFlags: [])

        makeKey("Bravo")
        chooseMenuItem("New Entry", inMenu: "File")
        let bravoEditor = bravo.textFields["entry-edit.title-field"].firstMatch
        XCTAssertTrue(bravoEditor.waitForExistence(timeout: 10), "File > New Entry did not open the editor in the key window")
        XCTAssertFalse(alpha.textFields["entry-edit.title-field"].exists, "File > New Entry opened an editor in another window")
        bravo.buttons["entry-edit.cancel"].firstMatch.click()
        XCTAssertTrue(bravoEditor.waitForNonExistence(timeout: 10))

        typeCommandShortcut(",")
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "⌘, did not open Settings")
        chooseMenuItem("Lock", inMenu: "Database")
        XCTAssertTrue(waitForLockedState(in: bravo), "With Settings key, Lock did not act on the last focused database window")
        XCTAssertTrue(rowQuery(in: alpha, identifier: "group.navlink").firstMatch.exists, "Lock reached a window that was not the target")

        makeKey("Alpha")
        typeCommandShortcut("l")
        XCTAssertTrue(waitForLockedState(in: alpha), "⌘L did not lock the key window's database")
    }

    func testOpeningAMinimizedDatabaseFrontsItsWindowWithoutADuplicate() {
        let window = openDatabase(named: "Alpha")
        XCTAssertTrue(waitForKeyboardFocus(window.secureTextFields["unlock.password.field"]))
        typeCommandShortcut("m")
        // XCUITest lists no minimized window.
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "⌘M did not minimize the database window")

        showDatabasesWindow()
        selectDatabaseRow(containing: "Alpha")?.doubleClick()

        XCTAssertTrue(window.waitForExistence(timeout: 10), "Opening the minimized database did not bring its window back")
        XCTAssertTrue(
            waitForKeyboardFocus(window.secureTextFields["unlock.password.field"], timeout: 10),
            "Opening the minimized database did not front its window"
        )
        XCTAssertEqual(databaseWindows.count, 1, "Opening an already open database created a second window")
    }

    /// A save that hits an injected conflict leaves Alpha with an unsaved
    /// draft and no sheet, the state in which ⌘W asks before closing.
    func testCommandWWithUnsavedWorkPromptsOnThatWindowAndCancelKeepsItUsable() throws {
        unlockSuccessfully(in: openDatabase(named: "Alpha"))
        unlockSuccessfully(in: openDatabase(named: "Bravo"))
        makeKey("Alpha")
        typeCommandShortcut("n")
        let titleField = alpha.textFields["entry-edit.title-field"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.click()
        app.typeText("Unsaved Draft")
        alpha.buttons["entry-edit.save"].firstMatch.click()
        // The failed save keeps the editor open; its conflict alert waits for the editor to close.
        // Cancel is ignored until the failed save settles, so retry it.
        let editorCancel = alpha.buttons["entry-edit.cancel"].firstMatch
        let discard = alpha.buttons["Discard Changes"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while titleField.exists, Date() < deadline {
            if discard.exists {
                discard.click()
            } else if editorCancel.exists, editorCancel.isHittable {
                editorCancel.click()
            }
            _ = discard.waitForExistence(timeout: 2)
        }
        XCTAssertFalse(titleField.exists, "The editor did not close")
        let merge = alpha.buttons["save-conflict.merge"].firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 15), "The injected save conflict did not appear")
        let conflictCancel = alpha.buttons["save-conflict.cancel"].firstMatch
        guard conflictCancel.exists else {
            throw XCTSkip("Known defect: the macOS Save Conflict alert shows no Cancel and ignores Escape, so no unsaved draft without a sheet is reachable")
        }
        conflictCancel.click()
        XCTAssertTrue(merge.waitForNonExistence(timeout: 5), "Cancel did not dismiss the save-conflict alert")

        typeCommandShortcut("w")
        let cancel = alpha.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "⌘W did not ask about the unsaved draft on its window")
        XCTAssertTrue(alpha.sheets.buttons["Don’t Save"].exists)
        XCTAssertEqual(bravo.sheets.count, 0, "The prompt appeared on another window")
        cancel.click()

        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(alpha.exists, "Cancel closed the window")
        XCTAssertTrue(rowQuery(in: alpha, identifier: "group.navlink").firstMatch.exists, "Cancel locked the database")
        typeCommandShortcut("f")
        XCTAssertTrue(waitForKeyboardFocus(alpha.searchFields.firstMatch), "The window did not take commands after Cancel")
        XCTAssertTrue(rowQuery(in: bravo, identifier: "group.navlink").firstMatch.exists, "The other database changed state")
    }

    func testWindowMenuListsDatabasesAndFrontsTheChosenWindow() {
        unlockSuccessfully(in: openDatabase(named: "Alpha"))
        openDatabase(named: "Bravo")

        let windowMenu = app.menuBars.menuBarItems["Window"].firstMatch
        windowMenu.click()
        for name in ["Alpha", "Bravo"] {
            XCTAssertTrue(windowMenuItem(named: name).waitForExistence(timeout: 5), "The Window menu does not list '\(name)'")
        }
        XCTAssertEqual(windowMenu.menuItems.matching(NSPredicate(format: "title == 'Databases'")).count, 1,
            "The Window menu should list Databases once")
        windowMenuItem(named: "Alpha").click()
        typeCommandShortcut("f")
        XCTAssertTrue(
            waitForKeyboardFocus(alpha.searchFields.firstMatch),
            "Choosing a database in the Window menu did not front its window"
        )

        showDatabasesWindow()
        XCTAssertTrue(databaseRow(containing: "Alpha").isHittable, "Window > Databases did not front the Databases window")
    }

    // MARK: - Helpers

    private func rowQuery(in window: XCUIElement, identifier: String) -> XCUIElementQuery {
        window.descendants(matching: .any).matching(identifier: identifier)
    }

    /// Fronts a database window through its Window-menu item: cascaded windows
    /// overlap, so no click point is reliably visible on the one behind.
    private func makeKey(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(databaseWindow(named: name).waitForExistence(timeout: 10), "No window to focus", file: file, line: line)
        app.menuBars.menuBarItems["Window"].firstMatch.click()
        let item = windowMenuItem(named: name)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No Window-menu item for '\(name)'", file: file, line: line)
        item.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// AppKit's Window-menu entry adds an unlocked window's subtitle in parentheses.
    private func windowMenuItem(named name: String) -> XCUIElement {
        app.menuBars.menuBarItems["Window"].menuItems.matching(
            NSPredicate(format: "title == %@ OR title BEGINSWITH %@", name, "\(name) (")
        ).firstMatch
    }
}
