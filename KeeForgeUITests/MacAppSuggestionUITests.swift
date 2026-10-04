import XCTest

/// The native Mac app suggestion only appears for the iOS app running on a
/// Mac, which no simulator is. This class forces it up via
/// UI_TEST_SHOW_MAC_APP_SUGGESTION=1, which also ignores any persisted
/// dismissal flag.
@MainActor
final class MacAppSuggestionUITests: KeeForgeUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_SHOW_MAC_APP_SUGGESTION"] = "1"
    }

    func testMacAppSuggestionShowsAndDismisses() {
        // A portrait iPad starts with the sidebar collapsed, and the banner
        // sits in that sidebar above the database list.
        revealSidebarIfNeeded()
        XCTAssertTrue(waitForDatabaseList(), "Database list did not appear")

        let openButton = app.buttons["mac-app-suggestion.open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10), "Mac app suggestion did not appear")

        let dismissButton = app.buttons["mac-app-suggestion.dismiss"]
        XCTAssertTrue(dismissButton.exists, "Mac app suggestion dismiss button missing")
        // Do not tap the open button: it leaves the app for the App Store.
        tapElement(dismissButton)

        let deadline = Date().addingTimeInterval(10)
        while openButton.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(openButton.exists, "Mac app suggestion did not dismiss")

        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(databaseRow.exists, "Database row disappeared after dismissing the suggestion")
        XCTAssertTrue(databaseRow.isHittable, "Database row not hittable after dismissing the suggestion")
    }
}
