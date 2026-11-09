import XCTest

/// iPhone Duo opening and closing, and an iPad window resizing, switch the app
/// between its compact and regular layouts. No simulator can open or close a
/// Duo from a test, so the app's `-ui-testing-layout-switch` control switches
/// the layout the way a size-class change does.
@MainActor
final class LayoutSwitchUITests: EntryEditUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        try super.configureLaunch(app: app)
        app.launchArguments += ["-ui-testing-layout-switch"]
    }

    func testOpenEntryStaysOpenAcrossLayoutSwitches() {
        unlockSuccessfully()
        openGroup(named: socialGroupName)
        openEntry(named: twitterEntryTitle)

        let passwordCopy = app.buttons["entry.copy.password"]
        XCTAssertTrue(passwordCopy.waitForExistence(timeout: Self.ciElementTimeout), "The entry did not open")
        for pass in 1...2 {
            switchLayout()
            XCTAssertTrue(
                passwordCopy.waitForExistence(timeout: Self.ciElementTimeout),
                "The entry closed when the layout changed (switch \(pass))"
            )
        }
    }

    func testUnsavedNewEntrySurvivesLayoutSwitches() {
        unlockSuccessfully()
        openGroup(named: workGroupName)
        tapAddEntry()

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: Self.ciElementTimeout), "The entry editor did not open")
        titleField.tap()
        titleField.typeText("Duo Draft")

        for pass in 1...2 {
            switchLayout()
            XCTAssertTrue(
                titleField.waitForExistence(timeout: Self.ciElementTimeout),
                "The editor closed when the layout changed (switch \(pass))"
            )
            XCTAssertEqual(titleField.value as? String, "Duo Draft", "The draft lost its title (switch \(pass))")
        }
    }

    private func switchLayout(file: StaticString = #filePath, line: UInt = #line) {
        let control = app.buttons["ui-testing.switch-layout"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "The layout switch is missing", file: file, line: line)
        control.tap()
    }
}
