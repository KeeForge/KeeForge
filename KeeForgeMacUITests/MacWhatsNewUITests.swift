import XCTest

@MainActor
final class MacWhatsNewUITests: MacUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_SHOW_WHATS_NEW"] = "1"
    }

    /// Deliberately version-agnostic: which features the sheet lists, and how
    /// `platforms:` filters them per platform, is covered exhaustively by
    /// `WhatsNewPresentationServiceTests`. Asserting concrete feature ids here
    /// only made this test rot on every release — it was still pinned to the
    /// 1.10.1 catalog after the Mac target moved into version lockstep with iOS.
    /// What this test uniquely proves is that the sheet renders in the real Mac
    /// app, lists something, and hands the window back on dismissal.
    func testWhatsNewShowsMacFeaturesAndDismisses() {
        let title = databasesWindow.staticTexts["whats-new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "What's New sheet did not appear on the Databases window")

        let features = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "whats-new.feature.")
        )
        XCTAssertGreaterThan(
            features.count,
            0,
            "What's New sheet appeared on Mac with no features listed"
        )

        let doneButton = databasesWindow.buttons["whats-new.done"]
        XCTAssertTrue(doneButton.exists, "What's New Done button was missing on Mac")
        doneButton.click()

        let deadline = Date().addingTimeInterval(10)
        while title.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(title.exists, "What's New sheet did not dismiss on Mac")

        XCTAssertTrue(
            databaseRow(containing: "test").waitForExistence(timeout: 10),
            "Database list did not resume after dismissing What's New on Mac"
        )
        XCTAssertEqual(databaseWindows.count, 0, "Dismissing What's New opened a database window")
    }
}
