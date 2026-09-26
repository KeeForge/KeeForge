import XCTest

/// Encryption-settings smoke path: create a fresh local database (AES-256,
/// compressed), switch it to ChaCha20 without compression from Database
/// Details, check the file header Database Details reads back, then prove the
/// database still unlocks with the unchanged master password.
@MainActor
final class EncryptionSettingsUITests: DatabaseCreationUITestCase {
    func testChangeCipherAndCompressionThenUnlockWithSamePassword() throws {
        let password = "encryption settings 123"

        createLocalDatabase(named: "Encryption Settings UI", password: password)

        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Unlocked database settings button was not visible")
        tapElement(settingsButton)

        let changeRow = app.buttons["database-details.change-encryption-settings"]
        XCTAssertTrue(revealElement(changeRow), "Change Encryption Settings row was not visible in Database Details")
        XCTAssertTrue(waitForEnabled(changeRow), "Change Encryption Settings row stayed disabled")
        tapElement(changeRow)

        let saveButton = app.buttons["encryption-settings.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Encryption settings save button was not visible")
        XCTAssertFalse(saveButton.isEnabled, "Save must stay disabled until a setting changes")

        let cipherPicker = app.buttons["encryption-settings.cipher-picker"]
        XCTAssertTrue(cipherPicker.waitForExistence(timeout: 5), "Cipher picker was not visible")
        tapElement(cipherPicker)
        let chachaOption = app.buttons["ChaCha20"].firstMatch
        XCTAssertTrue(chachaOption.waitForExistence(timeout: 5), "ChaCha20 was not offered")
        tapElement(chachaOption)

        let compressionToggle = app.switches["encryption-settings.compression-toggle"]
        XCTAssertTrue(revealElement(compressionToggle), "Compression toggle was not visible")
        setSwitch(compressionToggle, isOn: false)

        XCTAssertTrue(waitForEnabled(saveButton), "Save did not enable after changing settings")
        tapElement(saveButton)

        XCTAssertTrue(
            changeRow.waitForExistence(timeout: 30),
            "Encryption settings change did not return to Database Details"
        )
        XCTAssertFalse(
            app.otherElements["encryption-settings.error"].exists || app.staticTexts["encryption-settings.error"].exists,
            "Encryption settings change surfaced an error banner"
        )

        assertDetailsRow("database-details.encryption", contains: "ChaCha20")
        assertDetailsRow("database-details.compression", contains: "None")
        closeDatabaseDetails()

        let lockButton = currentLockButton()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button was not visible after the change")
        tapElement(lockButton)
        XCTAssertTrue(waitForLockedState(timeout: 10), "Locked state did not appear after locking")

        unlock(password: password)
        waitForVaultToUnlock()
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.isEnabled == false, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return element.isEnabled
    }

    /// The row re-reads the file header when the settings screen pops, so the
    /// new value can land a moment after the row itself is back on screen.
    private func assertDetailsRow(
        _ identifier: String,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(revealElement(row), "Database Details was missing '\(identifier)'", file: file, line: line)

        func rowText() -> String {
            ([row.label] + row.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
        }
        let deadline = Date().addingTimeInterval(10)
        while rowText().contains(expected) == false, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(
            rowText().contains(expected),
            "'\(identifier)' should show \(expected), got: \(rowText())",
            file: file,
            line: line
        )
    }
}
