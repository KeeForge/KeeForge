import XCTest

/// WebDAV mock round-trip on macOS, reusing the app's `UITestWebDAVCloudProvider`
/// (driven by `UI_TEST_WEBDAV_PAYLOAD_JSON`) exactly like the iOS
/// `WebDAVSeededUnlockUITests`: a connected account + cloud database reference
/// are seeded at launch, the database downloads through the mock provider on
/// unlock, and ⌘L locks it again.
@MainActor
final class MacWebDAVSmokeUITests: MacUITestCase {
    private static let webDAVPayloadEnv = "UI_TEST_WEBDAV_PAYLOAD_JSON"
    private static let cloudAccountsEnv = "UI_TEST_CLOUD_ACCOUNTS_JSON"
    private static let cloudDatabasesEnv = "UI_TEST_CLOUD_DATABASES_JSON"

    private static let accountID = "webdav-acct-1"
    private static let fileID = "/Vaults/personal.kdbx"

    override var databaseFixtures: [DatabaseFixture] { [] }

    override func configureLaunch(app: XCUIApplication) throws {
        let payload = try makeMockWebDAVPayload()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let payloadData = try encoder.encode(payload)
        app.launchEnvironment[Self.webDAVPayloadEnv] = String(decoding: payloadData, as: UTF8.self)

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

    func testSeededWebDAVDatabaseUnlocksViaMockProviderAndLocks() {
        unlockSuccessfully()
        let groupLink = app.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        XCTAssertTrue(groupLink.exists, "WebDAV-backed vault did not unlock")

        typeCommandShortcut("l")

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15), "⌘L did not lock the WebDAV-backed vault")
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
            connectError: nil,
            authenticateError: nil,
            listError: nil,
            metadataError: nil,
            downloadError: nil,
            uploadError: nil
        )
    }
}

// MARK: - Encodable payload models (mirror KeeForgeUITests/WebDAVSyncUITests)

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
