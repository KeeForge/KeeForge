import XCTest

@MainActor
final class UnlockFlowUITests: KeeForgeUITestCase {
    override var databaseFixtures: [DatabaseFixture] {
        [
            DatabaseFixture(resourceName: "test", injectedFilename: "test-primary.kdbx"),
            DatabaseFixture(resourceName: "test", injectedFilename: "test-secondary.kdbx"),
        ]
    }

    func testUnlockShowsErrorForWrongPassword() {
        unlock(password: "wrong-password")
        XCTAssertTrue(app.staticTexts["unlock.error.label"].waitForExistence(timeout: 10))
    }

    func testSingleDatabaseLaunchShowsListWhenQuickLaunchIsOff() {
        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(databaseRow.waitForExistence(timeout: 10), "Database list should appear on launch when quick launch is off")
    }

    func testBackToDatabaseListReturnsToHomeScreen() {
        XCTAssertTrue(openFirstDatabaseFromListIfNeeded(), "Unlock screen did not appear")

        let backButton = app.buttons["unlock.choose-different"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 10), "Back to Database List button not found")

        backButton.tap()

        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(databaseRow.waitForExistence(timeout: 10), "Database list did not appear after returning from unlock")
    }
}

@MainActor
final class QuickLaunchSmokeUITests: KeeForgeUITestCase {
    func testSingleDatabaseLaunchAutoOpensUnlockScreen() {
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(
            passwordField.waitForExistence(timeout: 10),
            "Quick Launch should open the unlock screen automatically when a single database is seeded"
        )

        unlockSuccessfully()

        XCTAssertTrue(currentLockButton().exists, "Vault should unlock successfully after quick-launch routing")
    }
}
