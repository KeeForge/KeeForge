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

    func testListSettingsHideLastOpenedStatAfterDisablingUsageStats() {
        unlockSuccessfully()

        let lockButton = currentLockButton()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button not found")
        tapElement(lockButton)
        XCTAssertTrue(waitForLockedState(timeout: 10), "Locked state did not appear after manual lock")

        let backToListButton = app.buttons["unlock.choose-different"].firstMatch
        if backToListButton.waitForExistence(timeout: 2) {
            backToListButton.tap()
        }

        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database list was not visible after locking")

        let settingsButton = app.buttons["database.settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Database list settings button was not visible")
        settingsButton.tap()

        let displayLink = app.descendants(matching: .any).matching(identifier: "settings.display.link").firstMatch
        XCTAssertTrue(displayLink.waitForExistence(timeout: 5), "Display link was not visible")
        tapElement(displayLink)

        let usageStatsToggle = app.switches["settings.display.usage-stats-toggle"]
        XCTAssertTrue(usageStatsToggle.waitForExistence(timeout: 5), "Usage stats toggle was not visible")
        setSwitch(usageStatsToggle, isOn: true)

        closeDisplaySettings()

        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database list should still be visible after closing settings")

        let usageStatAppearanceDeadline = Date().addingTimeInterval(5)
        while databaseRow(containing: "test-primary").label.contains("Last opened") == false, Date() < usageStatAppearanceDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTAssertTrue(
            databaseRow(containing: "test-primary").label.contains("Last opened"),
            "Expected the primary database row to include the last-opened usage stat before disabling it"
        )

        settingsButton.tap()

        XCTAssertTrue(displayLink.waitForExistence(timeout: 5), "Display link was not visible when reopening settings")
        tapElement(displayLink)

        XCTAssertTrue(usageStatsToggle.waitForExistence(timeout: 5), "Usage stats toggle was not visible when reopening display settings")
        setSwitch(usageStatsToggle, isOn: false)

        closeDisplaySettings()

        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database list should still be visible after closing settings")

        let disappearanceDeadline = Date().addingTimeInterval(5)
        while databaseRow(containing: "test-primary").label.contains("Last opened"), Date() < disappearanceDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTAssertFalse(
            databaseRow(containing: "test-primary").label.contains("Last opened"),
            "Last-opened usage stat should disappear from the primary database row after disabling it"
        )
    }

    private func closeDisplaySettings(file: StaticString = #filePath, line: UInt = #line) {
        let backToSettingsButton = app.navigationBars.buttons["Settings"].firstMatch
        XCTAssertTrue(backToSettingsButton.waitForExistence(timeout: 5), "Back to Settings button was not visible", file: file, line: line)
        tapElement(backToSettingsButton)

        let settingsBar = app.navigationBars["Settings"]
        let doneButton = settingsBar.buttons["Done"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Done button was not visible on the root settings page", file: file, line: line)
        tapElement(doneButton)
        XCTAssertFalse(settingsBar.waitForExistence(timeout: 2), "Settings sheet did not dismiss", file: file, line: line)
    }

    private func setSwitch(
        _ toggle: XCUIElement,
        isOn desiredValue: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(5)

        while switchIsOn(toggle) != desiredValue, Date() < deadline {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTAssertEqual(
            switchIsOn(toggle),
            desiredValue,
            "Expected usage stats toggle to be \(desiredValue ? "on" : "off")",
            file: file,
            line: line
        )
    }

    private func switchIsOn(_ toggle: XCUIElement) -> Bool {
        if let stringValue = toggle.value as? String {
            return stringValue == "1" || stringValue.caseInsensitiveCompare("on") == .orderedSame
        }

        if let numberValue = toggle.value as? NSNumber {
            return numberValue.boolValue
        }

        return false
    }
}

@MainActor
final class QuickLaunchSmokeUITests: KeeForgeUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_ENABLE_QUICK_LAUNCH"] = "1"
    }

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
