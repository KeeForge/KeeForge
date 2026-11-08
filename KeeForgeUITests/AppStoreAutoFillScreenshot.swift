import XCTest

/// Captures the AutoFill picker for the App Store listing through the DEBUG
/// harness's store variant. Opt-in like `AppStoreScreenshots`.
@MainActor
final class AppStoreAutoFillScreenshot: XCTestCase {
    func testCaptureAutoFillPicker() throws {
        guard ProcessInfo.processInfo.environment["APPSTORE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("App Store screenshot capture runs only with APPSTORE_SCREENSHOTS=1")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-autofill-picker-harness", "-autofill-picker-store"]
        app.launch()
        XCTAssertTrue(app.buttons["autofill.cancel"].waitForExistence(timeout: 30))
        sleep(2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "09-autofill-picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
