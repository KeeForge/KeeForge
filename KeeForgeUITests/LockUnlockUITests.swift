import XCTest

@MainActor
final class LockUnlockUITests: KeeForgeUITestCase {

    func testManualLockBehavior() {
        unlockSuccessfully()

        let lockButton = app.buttons["lock.button"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button not found")
        lockButton.tap()

        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(databaseRow.waitForExistence(timeout: 10), "Database list did not appear after locking")

        sleep(4)

        XCTAssertTrue(databaseRow.exists, "Database list should remain visible after manual lock")
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
