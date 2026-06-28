import XCTest

@MainActor
final class LockUnlockUITests: KeeForgeUITestCase {

    func testManualLockBehavior() {
        unlockSuccessfully()

        let lockButton = currentLockButton()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button not found")
        tapElement(lockButton)

        XCTAssertTrue(waitForLockedState(timeout: 10), "Locked state did not appear after manual lock")

        sleep(4)

        XCTAssertTrue(
            app.buttons["database.row"].exists || app.secureTextFields["unlock.password.field"].exists,
            "A locked landing screen should remain visible after manual lock"
        )
        XCTAssertFalse(
            app.buttons["lock.button"].exists,
            "Lock button should NOT exist — vault should remain locked after manual lock"
        )
    }

    func testFailedThenSuccessfulUnlock() {
        // Multiple wrong passwords show errors
        for attempt in 1...4 {
            unlock(password: "wrong-password-\(attempt)")

            let errorLabel = app.staticTexts["unlock.error.label"]
            XCTAssertTrue(errorLabel.waitForExistence(timeout: 15), "Error should appear on attempt \(attempt)")
        }

        // After multiple failures, should still be on unlock screen
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field should still be visible after failed attempts")

        waitForCurrentLockoutIfNeeded()

        // Now unlock with correct password
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

    private func waitForCurrentLockoutIfNeeded() {
        let errorLabel = app.staticTexts["unlock.error.label"]
        guard errorLabel.waitForExistence(timeout: 15) else { return }

        let errorText = errorLabel.label
        let seconds = errorText
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
            .first ?? 0

        if seconds > 0 {
            let waitDeadline = Date().addingTimeInterval(TimeInterval(seconds) + 2)
            while Date() < waitDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }
    }
}
