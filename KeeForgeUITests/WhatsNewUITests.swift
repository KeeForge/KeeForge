import XCTest

/// What's New is suppressed under `-ui-testing` unless this opt-in is set,
/// keeping every unrelated launch flow deterministic.
@MainActor
final class WhatsNewUITests: KeeForgeUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_SHOW_WHATS_NEW"] = "1"
        if ProcessInfo.processInfo.environment["WHATS_NEW_SCREENSHOTS"] == "1" {
            app.launchArguments.insert(contentsOf: [
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-KeeForge.appearanceMode", "light",
            ], at: 0)
        }
    }

    func testWhatsNewShowsFeatureRowsAndDismisses() {
        let title = app.staticTexts["whats-new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "What's New sheet did not appear")

        let featureRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "whats-new.feature.")
        )
        XCTAssertTrue(
            featureRows.firstMatch.waitForExistence(timeout: 5),
            "What's New sheet did not contain a feature row"
        )

        if ProcessInfo.processInfo.environment["WHATS_NEW_SCREENSHOTS"] == "1" {
            for page in 1...3 {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "whats-new-iphone-\(page)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if page < 3 {
                    app.scrollViews.firstMatch.swipeUp(velocity: .slow)
                }
            }
        }

        let doneButton = app.buttons["whats-new.done"]
        XCTAssertTrue(doneButton.exists, "What's New Done button was missing")
        doneButton.tap()

        let deadline = Date().addingTimeInterval(10)
        while title.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(title.exists, "What's New sheet did not dismiss")
        XCTAssertTrue(waitForDatabaseList(), "Database list did not resume after dismissal")
    }
}
