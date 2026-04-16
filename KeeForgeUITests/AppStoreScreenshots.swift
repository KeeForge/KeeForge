import XCTest

@MainActor
final class AppStoreScreenshots: KeeForgeUITestCase {
    private enum ScreenshotName: String {
        case databaseList = "01-database-list"
        case unlockScreen = "02-unlock-screen"
        case vaultGroups = "03-vault-groups"
        case databaseSettings = "04-database-settings"
        case entryList = "05-entry-list"
        case entryDetail = "06-entry-detail"
        case entryEdit = "07-entry-edit"
        case search = "08-search"
    }

    private struct CloudAccountPayload: Encodable {
        let id: String
        let displayName: String
        let provider: String
    }

    private struct CloudFilePayload: Encodable {
        let id: String
        let name: String
        let path: String
        let isFolder: Bool
        let modifiedDate: Date?
        let size: Int64?
    }

    private struct CloudDatabasePayload: Encodable {
        let provider: String
        let accountId: String
        let file: CloudFilePayload
    }

    private struct DropboxDirectoryPayload: Encodable {
        let path: String?
        let files: [CloudFilePayload]
    }

    private struct DropboxProviderPayload: Encodable {
        let accounts: [CloudAccountPayload]
        let directories: [DropboxDirectoryPayload]
        let fileContentsByID: [String: String]
        let contentHashByFileID: [String: String]
        let revByFileID: [String: String]
        let authenticateError: String?
        let listError: String?
        let metadataError: String?
        let downloadError: String?
        let uploadError: String?
    }

    private static let uiTestCloudDatabasesEnv = "UI_TEST_CLOUD_DATABASES_JSON"
    private static let uiTestCloudAccountsEnv = "UI_TEST_CLOUD_ACCOUNTS_JSON"
    private static let uiTestDropboxPayloadEnv = "UI_TEST_DROPBOX_PAYLOAD_JSON"

    private let demoPassword = "demo"

    override var databaseFixtures: [DatabaseFixture] {
        [
            DatabaseFixture(resourceName: "demo", injectedFilename: "Personal.kdbx"),
            DatabaseFixture(resourceName: "demo", injectedFilename: "Work.kdbx"),
        ]
    }

    override func configureLaunch(app: XCUIApplication) throws {
        let fixtureData = try fixtureData(resourceName: "demo", resourceExtension: "kdbx")
        let fixtureBase64 = fixtureData.base64EncodedString()

        let account = CloudAccountPayload(
            id: "acct-1",
            displayName: "alex@example.com",
            provider: "dropbox"
        )
        let cloudFile = CloudFilePayload(
            id: "/Vaults/shared-vault.kdbx",
            name: "Shared Vault.kdbx",
            path: "/Vaults/shared-vault.kdbx",
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 1_712_345_678),
            size: Int64(fixtureData.count)
        )

        app.launchEnvironment["UI_TEST_ENABLE_FAVICONS"] = "1"
        app.launchEnvironment[Self.uiTestCloudAccountsEnv] = try encode([account])
        app.launchEnvironment[Self.uiTestCloudDatabasesEnv] = try encode([
            CloudDatabasePayload(
                provider: "dropbox",
                accountId: account.id,
                file: cloudFile
            ),
        ])
        app.launchEnvironment[Self.uiTestDropboxPayloadEnv] = try encode(
            DropboxProviderPayload(
                accounts: [account],
                directories: [DropboxDirectoryPayload(path: nil, files: [cloudFile])],
                fileContentsByID: [cloudFile.id: fixtureBase64],
                contentHashByFileID: [cloudFile.id: "demo-content-hash"],
                revByFileID: [cloudFile.id: "demo-rev-1"],
                authenticateError: nil,
                listError: nil,
                metadataError: nil,
                downloadError: nil,
                uploadError: nil
            )
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func saveScreenshot(_ name: ScreenshotName) {
        sleep(1)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name.rawValue
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

    private func cloudDatabaseRow() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == 'database.row' AND label CONTAINS[c] %@", "Shared Vault")
        ).firstMatch
    }

    func testCaptureAllScreenshots() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database rows should appear on the home screen")
        XCTAssertTrue(cloudDatabaseRow().waitForExistence(timeout: 5), "Dropbox-backed database row should appear on the home screen")
        saveScreenshot(.databaseList)

        XCTAssertTrue(openFirstDatabaseFromListIfNeeded(), "Unlock sheet should appear after opening the first database")
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Password field should appear in unlock sheet")
        replaceText(in: passwordField, with: demoPassword)
        saveScreenshot(.unlockScreen)

        let unlockButton = app.buttons["unlock.button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5))
        unlockButton.tap()
        XCTAssertTrue(waitForVaultToUnlock(), "Vault should unlock with the demo fixture password")
        sleep(2)

        saveScreenshot(.vaultGroups)

        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Database settings button should be visible after unlock")
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Database Settings"].waitForExistence(timeout: 5), "Database Settings screen should open")
        sleep(1)
        saveScreenshot(.databaseSettings)

        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Close button should dismiss Database Settings")
        closeButton.tap()
        sleep(1)

        let primaryGroup = app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
            .first(where: { $0.label.contains("Social") })
            ?? app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
                .first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(primaryGroup, "A top-level group should exist after unlock")
        primaryGroup?.tap()
        sleep(2)
        saveScreenshot(.entryList)

        let entries = app.buttons.matching(identifier: "entry.navlink").allElementsBoundByIndex
        let totpEntry = entries.first(where: { $0.label.contains("Discord") })
            ?? entries.first(where: { $0.label.contains("Twitter") })
            ?? entries.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(totpEntry, "Should find an entry in the selected group")
        totpEntry?.tap()
        sleep(1)

        let revealButton = app.buttons["entry.password.reveal"]
        if revealButton.waitForExistence(timeout: 3) && revealButton.isHittable {
            revealButton.tap()
            sleep(1)
        }

        let totpCopy = app.buttons["entry.copy.totp"]
        if totpCopy.exists && !totpCopy.isHittable {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(1)
        }
        saveScreenshot(.entryDetail)

        let editButton = app.buttons["entry-detail.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "Edit button should be visible from entry detail")
        editButton.tap()
        XCTAssertTrue(app.textFields["entry-edit.title-field"].waitForExistence(timeout: 5), "Entry editor should appear")
        saveScreenshot(.entryEdit)

        let cancelButton = app.buttons["entry-edit.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()
        sleep(1)

        tapBackButton()
        tapBackButton()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field should be visible on GroupListView")
        searchField.tap()
        sleep(1)
        let activeSearchField = app.searchFields.firstMatch
        if activeSearchField.waitForExistence(timeout: 3) {
            activeSearchField.tap()
            sleep(1)
        }
        activeSearchField.typeText("git")
        sleep(2)
        saveScreenshot(.search)
    }
}
