import XCTest

/// Encryption-settings smoke paths: create a fresh local database (AES-256,
/// compressed, Argon2id), change its settings from Database Details, check the
/// file header Database Details reads back, then prove the database still
/// unlocks with the unchanged master password.
@MainActor
final class EncryptionSettingsUITests: DatabaseCreationUITestCase {
    func testChangeCipherAndCompressionThenUnlockWithSamePassword() throws {
        let password = "encryption settings 123"

        createLocalDatabase(named: "Encryption Settings UI", password: password)
        let saveButton = openEncryptionSettings()

        let cipherPicker = app.buttons["encryption-settings.cipher-picker"]
        XCTAssertTrue(cipherPicker.waitForExistence(timeout: 5), "Cipher picker was not visible")
        tapElement(cipherPicker)
        let chachaOption = app.buttons["ChaCha20"].firstMatch
        XCTAssertTrue(chachaOption.waitForExistence(timeout: 5), "ChaCha20 was not offered")
        tapElement(chachaOption)

        let compressionToggle = app.switches["encryption-settings.compression-toggle"]
        XCTAssertTrue(revealElement(compressionToggle), "Compression toggle was not visible")
        setSwitch(compressionToggle, isOn: false)

        saveAndReturnToDatabaseDetails(saveButton)

        assertDetailsRow("database-details.encryption", contains: "ChaCha20")
        assertDetailsRow("database-details.compression", contains: "None")
        closeDatabaseDetails()

        lockAndUnlock(password: password)
    }

    func testChangeKeyDerivationToAESKDFThenUnlockWithSamePassword() throws {
        let password = "aes kdf settings 123"

        createLocalDatabase(named: "AES-KDF Settings UI", password: password)
        let saveButton = openEncryptionSettings()

        XCTAssertFalse(
            app.textFields["encryption-settings.aes-kdf-rounds-field"].exists,
            "The rounds field belongs to AES-KDF only"
        )
        let kdfPicker = app.buttons["encryption-settings.kdf-preset-picker"]
        XCTAssertTrue(kdfPicker.waitForExistence(timeout: 5), "Key derivation picker was not visible")
        tapElement(kdfPicker)
        let aesKDFOption = app.buttons["AES-KDF"].firstMatch
        XCTAssertTrue(aesKDFOption.waitForExistence(timeout: 5), "AES-KDF was not offered")
        tapElement(aesKDFOption)

        let roundsField = app.textFields["encryption-settings.aes-kdf-rounds-field"]
        XCTAssertTrue(revealElement(roundsField), "AES-KDF rounds field was not visible")
        XCTAssertEqual(roundsField.value as? String, "1000000")

        saveAndReturnToDatabaseDetails(saveButton)

        assertDetailsRow("database-details.key-derivation", contains: "AES-KDF")
        assertDetailsRow("database-details.encryption", contains: "AES-256")
        closeDatabaseDetails()

        lockAndUnlock(password: password)
    }

    /// Opens Encryption Settings from the unlocked database and returns its
    /// Save button, which must start disabled.
    private func openEncryptionSettings(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 10),
            "Unlocked database settings button was not visible",
            file: file,
            line: line
        )
        tapElement(settingsButton)

        XCTAssertTrue(
            app.buttons["database-details.close"].waitForExistence(timeout: Self.ciElementTimeout),
            "The gear button did not open Database Details",
            file: file,
            line: line
        )
        openDatabaseDetailsPage(.encryption, file: file, line: line)

        let changeRow = app.buttons["database-details.change-encryption-settings"]
        XCTAssertTrue(
            revealElement(changeRow),
            "Change Encryption Settings row was not visible in Database Details",
            file: file,
            line: line
        )
        XCTAssertTrue(waitForEnabled(changeRow), "Change Encryption Settings row stayed disabled", file: file, line: line)
        tapElement(changeRow)

        let saveButton = app.buttons["encryption-settings.save"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 5),
            "Encryption settings save button was not visible",
            file: file,
            line: line
        )
        XCTAssertFalse(saveButton.isEnabled, "Save must stay disabled until a setting changes", file: file, line: line)
        return saveButton
    }

    private func saveAndReturnToDatabaseDetails(
        _ saveButton: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(waitForEnabled(saveButton), "Save did not enable after changing settings", file: file, line: line)
        tapElement(saveButton)

        XCTAssertTrue(
            app.buttons["database-details.change-encryption-settings"].waitForExistence(timeout: 30),
            "Encryption settings change did not return to Database Details",
            file: file,
            line: line
        )
        XCTAssertFalse(
            app.otherElements["encryption-settings.error"].exists || app.staticTexts["encryption-settings.error"].exists,
            "Encryption settings change surfaced an error banner",
            file: file,
            line: line
        )
    }

    private func lockAndUnlock(password: String, file: StaticString = #filePath, line: UInt = #line) {
        let lockButton = currentLockButton()
        XCTAssertTrue(
            lockButton.waitForExistence(timeout: 5),
            "Lock button was not visible after the change",
            file: file,
            line: line
        )
        tapElement(lockButton)
        XCTAssertTrue(waitForLockedState(timeout: 10), "Locked state did not appear after locking", file: file, line: line)

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
