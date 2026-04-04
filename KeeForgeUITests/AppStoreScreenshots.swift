import XCTest

@MainActor
final class AppStoreScreenshots: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()

        guard let fixtureURL = Bundle(for: AppStoreScreenshots.self).url(forResource: "demo", withExtension: "kdbx") else {
            throw NSError(domain: "Screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing demo.kdbx"])
        }

        let fixtureData = try Data(contentsOf: fixtureURL)
        let base64 = fixtureData.base64EncodedString()
        app.launchArguments += ["-ui-testing"]

        // Provide two databases so the database list screenshot shows multiple entries
        let databasesJSON = [
            ["filename": "Personal.kdbx", "base64": base64],
            ["filename": "Work.kdbx", "base64": base64]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: databasesJSON)
        app.launchEnvironment["UI_TEST_DATABASES_JSON"] = String(data: jsonData, encoding: .utf8)
        app.launchEnvironment["UI_TEST_ENABLE_FAVICONS"] = "1"
        app.launch()
    }

    private func saveScreenshot(_ name: String) {
        sleep(1) // Let animations settle
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapBackButton() {
        let toolbarIdentifiers = Set(["lock.button", "settings.button", "sort.menu", "Done"])

        let backButton = app.navigationBars.buttons.allElementsBoundByIndex.first { button in
            guard button.exists && button.isHittable else { return false }
            let identifier = button.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = button.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if toolbarIdentifiers.contains(identifier) || toolbarIdentifiers.contains(label) {
                return false
            }
            return true
        }

        if let backButton {
            backButton.tap()
            sleep(1)
        }
    }

    func testCaptureAllScreenshots() throws {
        // If the app auto-opened the unlock sheet, dismiss it first
        let passwordFieldEarly = app.secureTextFields["unlock.password.field"]
        if passwordFieldEarly.waitForExistence(timeout: 3) {
            let backButton = app.buttons["unlock.choose-different"]
            if backButton.exists && backButton.isHittable {
                backButton.tap()
                sleep(1)
            }
        }

        // 1. Database List — the multi-database home screen
        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(databaseRow.waitForExistence(timeout: 10), "Database row should appear on the home screen")
        saveScreenshot("01-database-list")

        // 2. Unlock Screen — sheet with password typed but not yet submitted
        databaseRow.tap()
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field should appear in unlock sheet")
        passwordField.tap()
        passwordField.typeText("demo")
        saveScreenshot("02-unlock-screen")

        // Unlock the database
        app.buttons["unlock.button"].tap()
        XCTAssertTrue(app.buttons["lock.button"].waitForExistence(timeout: 20), "Lock button should appear after unlock")
        sleep(2)

        // 3. Vault Groups — navigate into the Root group to show all subgroups
        let rootGroup = app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
            .first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(rootGroup, "Root group should exist after unlock")
        rootGroup!.tap()
        sleep(2)
        saveScreenshot("03-vault-groups")

        // 4. Entry List — Finance group with TOTP entries
        let financeGroup = app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
            .first(where: { $0.label.contains("Finance") })
        XCTAssertNotNil(financeGroup, "Finance group should exist inside Root")
        financeGroup!.tap()
        sleep(2)
        saveScreenshot("04-entry-list")

        // 5. Entry Detail — Coinbase with revealed password and TOTP countdown
        let entries = app.buttons.matching(identifier: "entry.navlink").allElementsBoundByIndex
        let totpEntry = entries.first(where: { $0.label.contains("Coinbase") })
            ?? entries.first(where: { $0.label.contains("Chase") })
            ?? entries.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(totpEntry, "Should find an entry in Finance group")
        totpEntry!.tap()
        sleep(1)

        // Reveal password to show color-coded text
        let revealButton = app.buttons["entry.password.reveal"]
        if revealButton.waitForExistence(timeout: 3) && revealButton.isHittable {
            revealButton.tap()
            sleep(1)
        }

        // Scroll down just enough to show TOTP without losing password
        let totpCopy = app.buttons["entry.copy.totp"]
        if totpCopy.exists && !totpCopy.isHittable {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(1)
        }

        saveScreenshot("05-entry-detail")

        // Navigate back: Entry Detail → Finance → Root (subgroups view)
        tapBackButton()
        tapBackButton()

        // 6. Settings — capture before search since search changes the view state
        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should be visible on GroupListView toolbar")
        settingsButton.tap()
        sleep(1)
        saveScreenshot("06-settings")

        // Dismiss settings sheet
        let closeButton = app.navigationBars["Settings"].buttons.firstMatch
        if closeButton.waitForExistence(timeout: 3) && closeButton.isHittable {
            closeButton.tap()
            sleep(1)
        }

        // 7. Search — search from the GroupListView
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field should be visible on GroupListView")
        searchField.tap()
        sleep(1)
        searchField.typeText("git")
        sleep(2)
        saveScreenshot("07-search")
    }
}
