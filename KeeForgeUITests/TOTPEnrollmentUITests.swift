import XCTest

// Enrollment smoke coverage for the entry editor's One-Time Password section:
// on an entry with no TOTP, "Enter Setup Key" opens the manual configuration
// rows, a typed Base32 secret saves, and entry detail then renders a live
// 6-digit code. Camera scanning cannot be driven by XCUITest (no simulator
// camera), and URI parsing is unit-tested (`OTPAuthURITests`,
// `EntryEditViewModelTests`); this class proves the UI wiring only.
@MainActor
final class TOTPEnrollmentUITests: UnlockedDatabaseUITestCase {
    // `autofill-union.kdbx`'s "Union Bank" entry carries no TOTP (only
    // "Union News" does); shares `test.kdbx`'s password, which the default
    // `unlockSuccessfully()` uses. See `TestFixtures/README.md`.
    override var databaseFixtureName: String { "autofill-union" }

    func testManualSetupKeyEnrollmentRendersCodeInDetail() {
        unlockSuccessfully()
        openFixtureEntry(groupName: "Union", entryName: "Union Bank")

        let editButton = app.buttons["entry-detail.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "Edit button was not visible")
        tapElement(editButton)

        let enterKeyButton = app.buttons["entry-edit.totp.enter-key"]
        XCTAssertTrue(
            revealElement(enterKeyButton, in: scrollableContainer()),
            "Enter Setup Key button was not visible"
        )
        tapElement(enterKeyButton)

        // Edit mode starts the secret concealed; reveal it so typing targets a
        // plain text field. The simulator has no passcode or enrolled
        // biometrics, so the device-owner gate falls through to a plain reveal.
        let visibilityButton = app.buttons["entry-edit.totp.secret-visibility-button"]
        XCTAssertTrue(
            revealElement(visibilityButton, in: scrollableContainer()),
            "TOTP secret visibility toggle was not visible"
        )
        tapElement(visibilityButton)

        let secretField = app.textFields["entry-edit.totp.secret-field"]
        XCTAssertTrue(
            revealElement(secretField, in: scrollableContainer()),
            "TOTP secret field was not visible"
        )
        replaceText(in: secretField, with: "JBSWY3DPEHPK3PXP")

        let saveButton = app.buttons["entry-edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Entry editor save button was not visible")
        tapElement(saveButton)
        XCTAssertTrue(
            waitForEditorDismissal(saveButton: saveButton),
            "Entry editor did not dismiss after save"
        )

        let totpCode = app.staticTexts["entry.totp.code"]
        XCTAssertTrue(
            revealElement(totpCode, in: scrollableContainer()),
            "TOTP code was not visible in entry detail after enrollment"
        )

        let code = totpCode.label
        XCTAssertEqual(code.count, 6, "Expected a 6-digit TOTP code, got '\(code)'")
        XCTAssertTrue(code.allSatisfy(\.isNumber), "Expected TOTP code to be numeric, got '\(code)'")
    }

    private func waitForEditorDismissal(saveButton: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if saveButton.exists == false {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return saveButton.exists == false
    }
}
