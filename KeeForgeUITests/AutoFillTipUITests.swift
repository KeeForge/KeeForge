import XCTest

/// The AutoFill enablement tip is suppressed by default under -ui-testing so
/// it cannot pollute unrelated tests or App Store screenshots. This class
/// opts back in via UI_TEST_SHOW_AUTOFILL_TIP=1, which pins the provider
/// state to disabled and ignores any persisted dismissal flag.
@MainActor
final class AutoFillTipUITests: KeeForgeUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_SHOW_AUTOFILL_TIP"] = "1"
    }

    func testAutoFillTipShowsAndDismisses() {
        XCTAssertTrue(waitForDatabaseList(), "Database list did not appear")

        let enableButton = app.buttons["autofill-tip.enable"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 10), "AutoFill tip banner did not appear")

        let dismissButton = app.buttons["autofill-tip.dismiss"]
        XCTAssertTrue(dismissButton.exists, "AutoFill tip dismiss button missing")
        // Do not tap the enable button: it triggers a system prompt /
        // backgrounds the app into iOS Settings.
        tapElement(dismissButton)

        let deadline = Date().addingTimeInterval(10)
        while enableButton.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(enableButton.exists, "AutoFill tip banner did not dismiss")

        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(databaseRow.exists, "Database row disappeared after dismissing the tip")
        XCTAssertTrue(databaseRow.isHittable, "Database row not hittable after dismissing the tip")
    }
}
