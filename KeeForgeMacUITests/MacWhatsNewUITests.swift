import XCTest

@MainActor
final class MacWhatsNewUITests: MacUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_SHOW_WHATS_NEW"] = "1"
    }

    func testWhatsNewShowsMacFeaturesAndDismisses() {
        let title = app.staticTexts["whats-new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "What's New sheet did not appear on Mac")

        XCTAssertTrue(
            app.descendants(matching: .any)["whats-new.feature.database-compatibility"].exists,
            "Database compatibility feature was missing on Mac"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["whats-new.feature.local-webdav"].exists,
            "WebDAV feature was missing on Mac"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["whats-new.feature.autofill-setup"].exists,
            "The iOS-only AutoFill feature should not appear on Mac"
        )

        let doneButton = app.buttons["whats-new.done"]
        XCTAssertTrue(doneButton.exists, "What's New Done button was missing on Mac")
        doneButton.click()

        let deadline = Date().addingTimeInterval(10)
        while title.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(title.exists, "What's New sheet did not dismiss on Mac")

        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(
            databaseRow.waitForExistence(timeout: 10),
            "Database list did not resume after dismissing What's New on Mac"
        )
    }
}
