import XCTest

// MARK: - Key file UI controls (uses default test.kdbx)

@MainActor
final class KeyFileUITests: KeeForgeUITestCase {

    private func findKeyFileSelect() -> XCUIElement? {
        let direct = app.buttons["unlock.keyfile.select"]
        if direct.waitForExistence(timeout: 8), direct.isHittable { return direct }

        if revealElement(direct, direction: .up, maxSwipes: 3), direct.isHittable {
            return direct
        }

        let byLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Select'")).firstMatch
        if byLabel.waitForExistence(timeout: 5), byLabel.isHittable { return byLabel }

        return nil
    }

    func testKeyFileSelectOpensDocumentPicker() {
        XCTAssertTrue(openFirstDatabaseFromListIfNeeded(), "Unlock screen did not appear")

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field not found")

        guard let selectButton = findKeyFileSelect() else {
            XCTFail("Key file Select button not found")
            return
        }
        selectButton.tap()

        XCTAssertTrue(
            waitForDocumentPicker(timeout: 15),
            "Document picker did not appear after tapping Select key file"
        )
    }
}

// MARK: - Key file unlock end-to-end (uses demo-keyfile.kdbx + demo-keyfile.key)

@MainActor
final class KeyFileUnlockUITests: KeeForgeUITestCase {

    override var databaseFixtureName: String { "demo-keyfile" }
    override var keyFileFixtureName: String? { "demo-keyfile" }
    override var keyFileFixtureExtension: String { "key" }

    /// Wait for key file injection to complete (name label appears in key file row).
    private func waitForKeyFileInjection() {
        XCTAssertTrue(openFirstDatabaseFromListIfNeeded(), "Unlock screen did not appear")

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field did not appear")

        // Wait for key file name to appear, confirming env var injection worked
        let keyFileLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'demo-keyfile'")).firstMatch
        XCTAssertTrue(keyFileLabel.waitForExistence(timeout: 15), "Key file name did not appear — injection may have failed")
    }

    private func unlockWithKeyFile() {
        waitForKeyFileInjection()

        // demo-keyfile.kdbx requires password "demo" + key file
        let passwordField = app.secureTextFields["unlock.password.field"]
        replaceText(in: passwordField, with: "demo")

        let unlockButton = app.buttons["unlock.button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 10), "Unlock button not found")
        unlockButton.tap()

        XCTAssertTrue(waitForVaultToUnlock(timeout: 30), "Vault did not unlock with password + key file")
    }

    func testKeyFileUnlockShowsEntries() {
        unlockWithKeyFile()

        // After unlock, entries should be visible (navigate into a group if needed)
        let entryLabel = firstVisibleEntryLabel()
        XCTAssertNotNil(entryLabel, "No entries visible after key file unlock")
    }
}
