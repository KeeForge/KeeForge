import XCTest

/// Change-master-key smoke path: create a fresh local database, rotate its
/// master password from Database Details, then prove the rotation stuck by
/// locking and unlocking with the new password. Extends
/// `DatabaseCreationUITestCase` for the empty-fixture launch and the
/// `UI_TEST_DATABASE_CREATION_EXPORT_PATH` export shortcut; the device-owner
/// confirmation is a no-op under `-ui-testing`.
@MainActor
final class MasterKeyChangeUITests: DatabaseCreationUITestCase {
    func testChangeMasterPasswordThenUnlockWithNewPassword() throws {
        let originalPassword = "original master 123"
        let newPassword = "rotated master 456"

        createLocalDatabase(named: "Rekey UI", password: originalPassword)

        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Unlocked database settings button was not visible")
        tapElement(settingsButton)

        let changeRow = app.buttons["database-details.change-master-key"]
        XCTAssertTrue(revealElement(changeRow), "Change Master Key row was not visible in Database Details")
        tapElement(changeRow)

        let newPasswordField = app.secureTextFields["master-key.new-password-field"]
        XCTAssertTrue(newPasswordField.waitForExistence(timeout: 5), "New master password field was not visible")
        let revealedNewPasswordField = revealPasswordTextField(
            in: newPasswordField,
            revealingWith: app.buttons["master-key.new-password-visibility-button"]
        )

        let confirmPasswordField = app.secureTextFields["master-key.confirm-password-field"]
        XCTAssertTrue(confirmPasswordField.waitForExistence(timeout: 5), "Confirm master password field was not visible")
        let revealedConfirmPasswordField = revealPasswordTextField(
            in: confirmPasswordField,
            revealingWith: app.buttons["master-key.confirm-password-visibility-button"]
        )

        replaceVisiblePasswordFixtureText(in: revealedNewPasswordField, with: newPassword)
        dismissKeyboardAfterPasswordFixtureEntry()
        replaceVisiblePasswordFixtureText(in: revealedConfirmPasswordField, with: newPassword)

        let saveButton = app.buttons["master-key.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Master key save button was not visible")
        tapElement(saveButton)

        // `.firstMatch`: SwiftUI propagates the identifier onto the dialog
        // button's inner elements, so the plain query is ambiguous.
        let confirmButton = app.buttons["master-key.confirm-change"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "Master key change confirmation was not shown")
        tapElement(confirmButton)

        XCTAssertTrue(
            changeRow.waitForExistence(timeout: 30),
            "Master key change did not dismiss back to Database Details"
        )
        XCTAssertFalse(
            app.otherElements["master-key.error"].exists || app.staticTexts["master-key.error"].exists,
            "Master key change surfaced an error banner"
        )
        closeDatabaseDetails()

        let lockButton = currentLockButton()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button was not visible after the change")
        tapElement(lockButton)
        XCTAssertTrue(waitForLockedState(timeout: 10), "Locked state did not appear after locking")

        unlock(password: newPassword)
        waitForVaultToUnlock()
    }
}
