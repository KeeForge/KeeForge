import XCTest

/// The menu bar quick-search panel renders in its own hosting view and has to
/// be handed the app's active session by the main window. The view-model tests
/// inject that session directly, so only the running app exercises the
/// hand-off.
@MainActor
final class MacQuickSearchUITests: MacUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        // Argument-domain override, so the status item appears without the
        // setting being saved. `-key value` pairs go before the bare
        // `-ui-testing` flag (see `MacUITestCase.setUp`).
        let arguments = ["-KeeForge.macMenuBarQuickAccess", "YES"]
        if let index = app.launchArguments.firstIndex(of: "-ui-testing") {
            app.launchArguments.insert(contentsOf: arguments, at: index)
        } else {
            app.launchArguments += arguments
        }
    }

    func testPanelFollowsTheActiveSessionThroughUnlockAndLock() {
        unlockSuccessfully()

        openPanel()
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 10),
            "The panel did not offer search for the unlocked database"
        )
        XCTAssertFalse(handOffButton.exists, "The panel sent an unlocked database back to the main window")
        closePanel()

        typeCommandShortcut("l")
        XCTAssertTrue(
            app.secureTextFields["unlock.password.field"].waitForExistence(timeout: 15),
            "⌘L did not lock the database"
        )

        openPanel()
        XCTAssertTrue(handOffButton.waitForExistence(timeout: 10), "The locked panel did not offer the main window")
        XCTAssertEqual(displayText(of: handOffButton), "Unlock…")
        XCTAssertTrue(
            panel.staticTexts.matching(NSPredicate(format: "label == 'test' OR value == 'test'")).firstMatch.exists,
            "The locked panel did not name the database"
        )
        XCTAssertFalse(searchField.exists, "The panel still offered search after the database locked")
    }

    private var panel: XCUIElement {
        app.dialogs["quick-search.panel"].firstMatch
    }

    private var searchField: XCUIElement {
        panel.textFields["quick-search.field"].firstMatch
    }

    private var handOffButton: XCUIElement {
        panel.buttons["quick-search.open-main-window"].firstMatch
    }

    private func openPanel(file: StaticString = #filePath, line: UInt = #line) {
        let statusItem = app.statusItems["menu-bar.quick-search.status-item"].firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "The menu bar item did not appear", file: file, line: line)
        statusItem.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The quick-search panel did not open", file: file, line: line)
    }

    private func closePanel(file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey(.escape, modifierFlags: [])
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: panel)
        wait(for: [closed], timeout: 10)
    }
}
