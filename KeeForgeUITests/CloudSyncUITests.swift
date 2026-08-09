import XCTest

@MainActor
class CloudSyncBaseUITests: KeeForgeUITestCase {
    private static let dropboxPayloadEnv = "UI_TEST_DROPBOX_PAYLOAD_JSON"
    private static let cloudAccountsEnv = "UI_TEST_CLOUD_ACCOUNTS_JSON"
    private static let cloudDatabasesEnv = "UI_TEST_CLOUD_DATABASES_JSON"

    override var databaseFixtures: [KeeForgeUITestCase.DatabaseFixture] {
        []
    }

    var seedsCloudDatabaseOnLaunch: Bool { false }

    override func configureLaunch(app: XCUIApplication) throws {
        let payload = try makeMockDropboxPayload()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        app.launchEnvironment[Self.dropboxPayloadEnv] = String(decoding: data, as: UTF8.self)

        guard seedsCloudDatabaseOnLaunch else { return }

        let cloudAccountsData = try encoder.encode(payload.accounts)
        app.launchEnvironment[Self.cloudAccountsEnv] = String(decoding: cloudAccountsData, as: UTF8.self)

        let cloudDatabasesData = try encoder.encode([
            MockCloudDatabase(
                provider: "dropbox",
                accountId: "acct-1",
                file: try XCTUnwrap(payload.directories.first?.files.first)
            )
        ])
        app.launchEnvironment[Self.cloudDatabasesEnv] = String(decoding: cloudDatabasesData, as: UTF8.self)
    }

    func addDropboxFromEmptyState(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let addButton = app.buttons["database.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), file: file, line: line)
        addButton.tap()

        let dropboxButton = menuButton(identifier: "database.add.dropbox", label: "Dropbox")
        XCTAssertTrue(dropboxButton.waitForExistence(timeout: 10), file: file, line: line)
        dropboxButton.tap()
    }

    func connectMockDropbox(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let connectButton = app.buttons["cloud.browser.connect.button"].firstMatch
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10), file: file, line: line)
        connectButton.tap()
    }

    private func makeMockDropboxPayload() throws -> MockDropboxPayload {
        let databaseData = try fixtureData(resourceName: "test", resourceExtension: "kdbx")
        let fileID = "/Vaults/personal.kdbx"
        let modifiedDate = Date(timeIntervalSince1970: 1_700_000_000)

        return MockDropboxPayload(
            accounts: [
                .init(id: "acct-1", displayName: "alex@example.com", provider: "dropbox")
            ],
            directories: [
                .init(
                    path: nil,
                    files: [
                        .init(
                            id: fileID,
                            name: "personal.kdbx",
                            path: fileID,
                            isFolder: false,
                            modifiedDate: modifiedDate,
                            size: Int64(databaseData.count)
                        )
                    ]
                )
            ],
            fileContentsByID: [
                fileID: databaseData.base64EncodedString()
            ],
            contentHashByFileID: [:],
            authenticateError: nil,
            listError: nil,
            metadataError: nil,
            downloadError: nil
        )
    }
}

@MainActor
final class CloudBrowserSmokeUITests: CloudSyncBaseUITests {
    func testAddDropboxShowsMockCloudFileInBrowser() {
        addDropboxFromEmptyState()
        connectMockDropbox()

        let fileRow = app.buttons.matching(
            NSPredicate(format: "identifier == 'cloud.browser.file.row' AND label CONTAINS[c] %@", "personal.kdbx")
        ).firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 10))
    }
}

@MainActor
final class CloudUnlockSmokeUITests: CloudSyncBaseUITests {
    override var seedsCloudDatabaseOnLaunch: Bool { true }

    func testSeededCloudDatabaseUnlocksViaMockProvider() {
        unlockSuccessfully()

        XCTAssertTrue(app.buttons["lock.button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings.button"].exists)
    }
}

final class CloudAccountEdgeUITests: CloudSyncBaseUITests {
    override var seedsCloudDatabaseOnLaunch: Bool { true }

    func testSigningOutDropboxAccountMarksCloudDatabaseDisconnected() {
        unlockSuccessfully()

        let lockButton = app.buttons["lock.button"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 10))
        lockButton.tap()

        let listSettingsButton = app.buttons["database.settings.button"]
        XCTAssertTrue(listSettingsButton.waitForExistence(timeout: 10))
        listSettingsButton.tap()

        let signOutButton = app.buttons["settings.cloud.signout.button"].firstMatch
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 10))
        signOutButton.tap()

        let disconnectButton = app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 10))
        disconnectButton.tap()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 10))
        doneButton.tap()

        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Cache unavailable"].exists)
    }
}

private struct MockDropboxPayload: Encodable {
    let accounts: [MockCloudAccount]
    let directories: [MockCloudDirectory]
    let fileContentsByID: [String: String]
    let contentHashByFileID: [String: String]
    let authenticateError: String?
    let listError: String?
    let metadataError: String?
    let downloadError: String?
}

private struct MockCloudAccount: Encodable {
    let id: String
    let displayName: String
    let provider: String
}

private struct MockCloudDirectory: Encodable {
    let path: String?
    let files: [MockCloudFile]
}

private struct MockCloudDatabase: Encodable {
    let provider: String
    let accountId: String
    let file: MockCloudFile
}

private struct MockCloudFile: Encodable {
    let id: String
    let name: String
    let path: String
    let isFolder: Bool
    let modifiedDate: Date?
    let size: Int64?
}
