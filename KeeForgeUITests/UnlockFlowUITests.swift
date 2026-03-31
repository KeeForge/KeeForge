import XCTest

@MainActor
final class UnlockFlowUITests: KeeForgeUITestCase {
    func testUnlockShowsErrorForWrongPassword() {
        unlock(password: "wrong-password")
        XCTAssertTrue(app.staticTexts["unlock.error.label"].waitForExistence(timeout: 10))
    }

    func testChooseDifferentFileShowsDocumentPicker() {
        // Unlock first, then lock to get back to unlock screen with "Choose Different File"
        unlockSuccessfully()

        let lockButton = app.buttons["lock.button"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 10), "Lock button not found")
        lockButton.tap()

        // Wait for unlock screen
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field did not appear after locking")

        // Tap "Choose Different File"
        let chooseDifferent = app.buttons["unlock.choose-different"]
        XCTAssertTrue(chooseDifferent.waitForExistence(timeout: 10), "Choose Different File button not found")
        chooseDifferent.tap()

        XCTAssertTrue(
            waitForDocumentPicker(timeout: 15),
            "Document picker did not appear after tapping Choose Different File"
        )
    }
}
