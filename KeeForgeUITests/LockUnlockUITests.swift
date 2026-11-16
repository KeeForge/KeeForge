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

    func testManualLockOnCompactReturnsToTheDatabaseList() throws {
        unlockSuccessfully()
        guard usesRegularWidthLayout == false else {
            throw XCTSkip("The regular layout keeps the locked database in the detail column")
        }

        tapElement(currentLockButton())

        XCTAssertTrue(app.buttons["database.row"].waitForExistence(timeout: 10), "A manual lock must return to the database list")
        XCTAssertFalse(app.secureTextFields["unlock.password.field"].exists)
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

/// An automatic lock leaves the database on its unlock page, where biometric
/// auto-unlock runs, instead of closing it back to the list (#312). The
/// simulator has no enrolled biometrics, so the page shows the password form.
@MainActor
class AutomaticLockUnlockPageUITestCase: KeeForgeUITestCase {
    func leaveAndReturnToTheApp() {
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 10)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
    }

    func assertLandsOnTheUnlockPage(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.secureTextFields["unlock.password.field"].waitForExistence(timeout: 10),
            "An automatic lock must leave the database on its unlock page",
            file: file,
            line: line
        )
        XCTAssertFalse(app.buttons["lock.button"].exists, "The vault must be locked", file: file, line: line)

        unlockSuccessfully(file: file, line: line)
    }
}

@MainActor
final class BackgroundLockUnlockPageUITests: AutomaticLockUnlockPageUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchArguments += ["-KeeForge.lockOnBackground", "YES"]
    }

    func testBackgroundLockStaysOnTheUnlockPage() {
        unlockSuccessfully()

        leaveAndReturnToTheApp()

        assertLandsOnTheUnlockPage()
    }
}

@MainActor
final class InactivityLockUnlockPageUITests: AutomaticLockUnlockPageUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchArguments += ["-KeeForge.lockOnBackground", "NO", "-KeeForge.autoLockTimeout", "Immediately"]
    }

    func testInactivityLockStaysOnTheUnlockPage() {
        unlockSuccessfully()

        leaveAndReturnToTheApp()

        assertLandsOnTheUnlockPage()
    }
}
