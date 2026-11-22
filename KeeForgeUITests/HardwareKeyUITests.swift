import XCTest

/// The YubiKey unlock flow on the real screens, answered by the app's
/// debug-only emulated key (`UI_TEST_YUBIKEY_SECRET`) in place of NFC.
@MainActor
final class HardwareKeyUITests: KeeForgeUITestCase {
    /// `HMAC_SECRET` in `TestFixtures/generators/challenge_response.py`.
    private static let fixtureSecret = "KeeForgeYubiKeyTest!"
    private static let fixturePassword = "challenge-response"

    override var databaseFixtureName: String { "challenge-response" }

    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_YUBIKEY_SECRET"] = name.contains("WrongYubiKey")
            ? "another-yubikey-secr"
            : Self.fixtureSecret
    }

    func testChoosingTheYubiKeyUnlocksAndItIsAskedAgainAfterLock() {
        XCTAssertTrue(openFirstDatabaseFromListIfNeeded(), "Unlock screen did not appear")
        chooseSlotTwo()

        unlock(password: Self.fixturePassword)
        XCTAssertEqual(pollUnlockOutcome(timeout: 30), .unlocked, "The emulated YubiKey did not unlock the database")

        let lockButton = app.buttons["lock.button"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 10), "Lock button not found")
        tapElement(lockButton)
        unlock(password: Self.fixturePassword)
        XCTAssertEqual(pollUnlockOutcome(timeout: 30), .unlocked, "The remembered YubiKey choice did not unlock again")
    }

    func testWrongYubiKeyIsRejected() {
        XCTAssertTrue(openFirstDatabaseFromListIfNeeded(), "Unlock screen did not appear")
        chooseSlotTwo()

        unlock(password: Self.fixturePassword)

        XCTAssertEqual(pollUnlockOutcome(timeout: 20), .failed, "Another YubiKey must not open the database")
        XCTAssertTrue(app.secureTextFields["unlock.password.field"].exists, "The unlock form stays available")
    }

    private func chooseSlotTwo() {
        let picker = app.buttons["unlock.hardware-key.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Hardware Key row not shown with the emulated key")
        tapElement(picker)
        let slotTwo = app.buttons["YubiKey via NFC, Slot 2"]
        XCTAssertTrue(slotTwo.waitForExistence(timeout: 5), "Slot 2 not offered")
        tapElement(slotTwo)
        XCTAssertTrue(
            app.staticTexts["YubiKey via NFC, Slot 2"].waitForExistence(timeout: 5)
                || picker.label.contains("Slot 2"),
            "The chosen slot is not shown"
        )
    }
}
