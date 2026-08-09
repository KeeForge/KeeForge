import XCTest

/// UI tests for WebDAV cloud sync driven by `UITestWebDAVCloudProvider`. Mirrors
/// the Dropbox `CloudSyncBaseUITests` conventions: the payload is seeded through
/// `UI_TEST_WEBDAV_PAYLOAD_JSON`, and the seeded-unlock path additionally seeds
/// `UI_TEST_CLOUD_ACCOUNTS_JSON` / `UI_TEST_CLOUD_DATABASES_JSON`.
@MainActor
class WebDAVSyncBaseUITests: KeeForgeUITestCase {
    private static let webDAVPayloadEnv = "UI_TEST_WEBDAV_PAYLOAD_JSON"
    private static let cloudAccountsEnv = "UI_TEST_CLOUD_ACCOUNTS_JSON"
    private static let cloudDatabasesEnv = "UI_TEST_CLOUD_DATABASES_JSON"

    private static let accountID = "webdav-acct-1"
    private static let fileID = "/Vaults/personal.kdbx"

    override var databaseFixtures: [KeeForgeUITestCase.DatabaseFixture] {
        []
    }

    /// Seed a connected account + cloud database reference so the app launches
    /// straight into the seeded-unlock path (Test 3).
    var seedsCloudDatabaseOnLaunch: Bool { false }

    /// When true, the payload's `connect(_:)` is configured to fail (Test 2).
    var simulatesConnectFailure: Bool { false }

    override func configureLaunch(app: XCUIApplication) throws {
        let payload = try makeMockWebDAVPayload()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        app.launchEnvironment[Self.webDAVPayloadEnv] = String(decoding: data, as: UTF8.self)

        guard seedsCloudDatabaseOnLaunch else { return }

        let cloudAccountsData = try encoder.encode(payload.accounts)
        app.launchEnvironment[Self.cloudAccountsEnv] = String(decoding: cloudAccountsData, as: UTF8.self)

        let cloudDatabasesData = try encoder.encode([
            MockCloudDatabase(
                provider: "webdav",
                accountId: Self.accountID,
                file: try XCTUnwrap(payload.directories.first?.files.first)
            )
        ])
        app.launchEnvironment[Self.cloudDatabasesEnv] = String(decoding: cloudDatabasesData, as: UTF8.self)
    }

    // MARK: - Flow helpers

    func addWebDAVFromEmptyState(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let addButton = app.buttons["database.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15), "Empty-state add button did not appear", file: file, line: line)
        addButton.tap()

        let webDAVButton = menuButton(identifier: "database.add.webdav", label: "WebDAV")
        XCTAssertTrue(webDAVButton.waitForExistence(timeout: 10), "WebDAV add-menu entry did not appear", file: file, line: line)
        webDAVButton.tap()
    }

    func openConnectForm(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let connectButton = app.buttons["cloud.browser.connect.button"].firstMatch
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10), "Cloud browser connect button did not appear", file: file, line: line)
        connectButton.tap()

        let serverField = app.textFields["webdav.connect.server-field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "WebDAV connect form did not appear", file: file, line: line)
    }

    func fillAndSubmitConnectForm(
        server: String = "https://cloud.example.com/remote.php/dav/files/alex/",
        username: String = "alex",
        password: String = "app-password",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let serverField = app.textFields["webdav.connect.server-field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Server field missing", file: file, line: line)
        serverField.tap()
        serverField.typeText(server)

        let usernameField = app.textFields["webdav.connect.username-field"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5), "Username field missing", file: file, line: line)
        usernameField.tap()
        usernameField.typeText(username)

        let passwordField = app.secureTextFields["webdav.connect.password-field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Password field missing", file: file, line: line)
        passwordField.tap()
        passwordField.typeText(password)

        let submitButton = app.buttons["webdav.connect.submit"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5), "Submit button missing", file: file, line: line)
        submitButton.tap()
    }

    // MARK: - Payload

    private func makeMockWebDAVPayload() throws -> MockWebDAVPayload {
        let databaseData = try fixtureData(resourceName: "test", resourceExtension: "kdbx")
        let modifiedDate = Date(timeIntervalSince1970: 1_700_000_000)

        return MockWebDAVPayload(
            accounts: [
                .init(id: Self.accountID, displayName: "alex@cloud.example.com", provider: "webdav")
            ],
            directories: [
                .init(
                    path: nil,
                    files: [
                        .init(
                            id: Self.fileID,
                            name: "personal.kdbx",
                            path: Self.fileID,
                            isFolder: false,
                            modifiedDate: modifiedDate,
                            size: Int64(databaseData.count)
                        )
                    ]
                )
            ],
            fileContentsByID: [
                Self.fileID: databaseData.base64EncodedString()
            ],
            contentHashByFileID: [:],
            revByFileID: [Self.fileID: "\"etag-personal\""],
            connectError: simulatesConnectFailure ? "notAuthenticated" : nil,
            authenticateError: nil,
            listError: nil,
            metadataError: nil,
            downloadError: nil,
            uploadError: nil
        )
    }
}

@MainActor
final class WebDAVAddFlowUITests: WebDAVSyncBaseUITests {
    func testAddWebDAVConnectsAndShowsMockFileInBrowser() {
        addWebDAVFromEmptyState()
        openConnectForm()
        fillAndSubmitConnectForm()

        let fileRow = app.buttons.matching(
            NSPredicate(format: "identifier == 'cloud.browser.file.row' AND label CONTAINS[c] %@", "personal.kdbx")
        ).firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 15), "Mock kdbx file row did not appear after connecting")
    }
}

@MainActor
final class WebDAVConnectErrorUITests: WebDAVSyncBaseUITests {
    override var simulatesConnectFailure: Bool { true }

    func testConnectErrorKeepsFormUpAndShowsError() {
        addWebDAVFromEmptyState()
        openConnectForm()
        fillAndSubmitConnectForm()

        let errorLabel = app.staticTexts["webdav.connect.error"]
        XCTAssertTrue(errorLabel.waitForExistence(timeout: 15), "Connect error was not surfaced")

        // The form must remain presented after a failed connect.
        XCTAssertTrue(app.textFields["webdav.connect.server-field"].exists, "Connect form should stay up after a failed connect")

        // No file row should appear since the connect failed.
        let fileRow = app.buttons.matching(identifier: "cloud.browser.file.row").firstMatch
        XCTAssertFalse(fileRow.exists, "No file row should appear after a failed connect")
    }
}

@MainActor
final class WebDAVSeededUnlockUITests: WebDAVSyncBaseUITests {
    override var seedsCloudDatabaseOnLaunch: Bool { true }

    func testSeededWebDAVDatabaseUnlocksViaMockProvider() {
        unlockSuccessfully()

        XCTAssertTrue(app.buttons["lock.button"].waitForExistence(timeout: 15), "Vault did not reach unlocked state")
    }
}

// MARK: - Encodable payload models

private struct MockWebDAVPayload: Encodable {
    let accounts: [MockCloudAccount]
    let directories: [MockCloudDirectory]
    let fileContentsByID: [String: String]
    let contentHashByFileID: [String: String]
    let revByFileID: [String: String]?
    let connectError: String?
    let authenticateError: String?
    let listError: String?
    let metadataError: String?
    let downloadError: String?
    let uploadError: String?
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
