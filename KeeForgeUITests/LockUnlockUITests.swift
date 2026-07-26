import XCTest

@MainActor
final class LockUnlockUITests: KeeForgeUITestCase {

    func testManualLockBehavior() {
        unlockSuccessfully()

        let lockButton = currentLockButton()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button not found")
        tapElement(lockButton)

        XCTAssertTrue(waitForLockedState(timeout: 10), "Locked state did not appear after manual lock")

        // Explicit wait for the locked-state element instead of a blind sleep:
        // poll until the lock button truly settles out of existence rather than
        // assuming a fixed delay is long enough.
        XCTAssertTrue(
            app.buttons["lock.button"].waitForNonExistence(timeout: 10),
            "Lock button should NOT exist — vault should remain locked after manual lock"
        )
        XCTAssertTrue(
            app.buttons["database.row"].exists || app.secureTextFields["unlock.password.field"].exists,
            "A locked landing screen should remain visible after manual lock"
        )
    }

    // Repeated-failure/lockout behavior is BackoffUITests' responsibility
    // (5 wrong unlocks asserting the backoff message); this test only proves
    // a single wrong attempt surfaces an error before the correct password
    // unlocks normally.
    func testWrongThenCorrectPasswordUnlocks() {
        unlock(password: "wrong-password")

        let errorLabel = app.staticTexts["unlock.error.label"]
        XCTAssertTrue(errorLabel.waitForExistence(timeout: 15), "Error should appear after a wrong password")

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field should still be visible after the failed attempt")

        unlock(password: "testpassword123")
        waitForVaultToUnlock(timeout: 30)
    }

    func testUnlockPasswordVisibilityToggleShowsTypedPassword() {
        openFirstDatabaseFromListIfNeeded()

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field did not appear")
        replaceText(in: passwordField, with: "testpassword123")

        let visibilityButton = app.buttons["unlock.password-visibility-button"]
        XCTAssertTrue(visibilityButton.waitForExistence(timeout: 5), "Password visibility button did not appear")
        visibilityButton.tap()

        let visiblePasswordField = app.textFields["unlock.password.field"]
        XCTAssertTrue(visiblePasswordField.waitForExistence(timeout: 5), "Visible password field did not appear")
        XCTAssertEqual(visiblePasswordField.value as? String, "testpassword123")

        visibilityButton.tap()
        XCTAssertTrue(
            app.secureTextFields["unlock.password.field"].waitForExistence(timeout: 5),
            "Password field should become secure again after hiding"
        )
    }
}
