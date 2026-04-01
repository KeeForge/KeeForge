import XCTest

@MainActor
final class UnlockFlowUITests: KeeForgeUITestCase {
    func testUnlockShowsErrorForWrongPassword() {
        unlock(password: "wrong-password")
        XCTAssertTrue(app.staticTexts["unlock.error.label"].waitForExistence(timeout: 10))
    }

    func testSingleDatabaseLaunchAutoNavigatesToUnlockScreen() {
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field should appear on launch when exactly one database is registered")
    }

    func testBackToDatabaseListReturnsToHomeScreen() {
        let backButton = app.buttons["unlock.choose-different"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 10), "Back to Database List button not found")

        backButton.tap()

        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(databaseRow.waitForExistence(timeout: 10), "Database list did not appear after returning from unlock")
    }
}
