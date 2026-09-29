import XCTest
@testable import KeeForge

final class DatabaseReferenceTests: XCTestCase {
    func testDecodeLegacyJSONWithoutNewFieldsSetsDefaults() throws {
        let legacy = LegacyDatabaseReferencePayload(
            id: UUID(),
            nickname: "Legacy",
            filename: "legacy.kdbx",
            bookmarkData: Data("bookmark".utf8),
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: Date(timeIntervalSince1970: 20),
            addedAt: Date(timeIntervalSince1970: 10),
            colorTag: "blue",
            legacyKeychainFilename: nil,
            source: .local
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(DatabaseReference.self, from: data)

        XCTAssertFalse(decoded.isReadOnly)
        XCTAssertTrue(decoded.autoFillEnabled)
        XCTAssertNil(decoded.autoFillDestinationGroupID)
        XCTAssertFalse(decoded.isDocumentsResident)
        XCTAssertEqual(decoded.cloudSyncPolicy, .onOpen)
        XCTAssertNil(decoded.hardwareKey)
    }

    func testEncodeDecodeWithNewFieldsRoundTrips() throws {
        let reference = DatabaseReference(
            id: UUID(),
            nickname: "Vault",
            filename: "vault.kdbx",
            bookmarkData: Data("bookmark".utf8),
            keyFileBookmarkData: Data("key".utf8),
            keyFileFilename: "vault.keyx",
            isQuickLaunch: true,
            lastOpenedAt: Date(timeIntervalSince1970: 20),
            addedAt: Date(timeIntervalSince1970: 10),
            colorTag: "green",
            legacyKeychainFilename: "legacy",
            isReadOnly: true,
            autoFillEnabled: false,
            autoFillDestinationGroupID: UUID(),
            isDocumentsResident: true,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/vault.kdbx",
                    displayPath: "/Vaults/vault.kdbx",
                    remoteContentHash: "hash",
                    remoteModifiedAt: Date(timeIntervalSince1970: 40),
                    remoteRev: "rev-123",
                    lastSyncedAt: Date(timeIntervalSince1970: 50),
                    lastSyncIssue: nil
                )
            ),
            hardwareKey: HardwareKeyConfiguration(transport: .lightning, slot: .two)
        )

        let data = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(DatabaseReference.self, from: data)

        XCTAssertEqual(decoded, reference)
    }

    func testManualCloudSyncPolicyRoundTrips() throws {
        var reference = makeCloudReference()
        reference.cloudSyncPolicy = .manual

        let data = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(DatabaseReference.self, from: data)

        XCTAssertEqual(decoded.cloudSyncPolicy, .manual)
        XCTAssertEqual(decoded, reference)
    }

    /// The stored list decodes all-or-nothing, so a policy this build does not
    /// know must not throw: that would empty the user's database list.
    func testUnknownCloudSyncPolicyDecodesAsSyncOnOpen() throws {
        var reference = makeCloudReference()
        reference.cloudSyncPolicy = .manual
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any]
        )
        json["cloudSyncPolicy"] = "someFuturePolicy"

        let decoded = try JSONDecoder().decode(
            DatabaseReference.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertEqual(decoded.cloudSyncPolicy, .onOpen)
        XCTAssertEqual(decoded.id, reference.id)
    }

    func testEncodeAlwaysEmitsAutoFillEnabledKey() throws {
        let reference = DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 10),
            colorTag: nil,
            legacyKeychainFilename: nil
        )

        let data = try JSONEncoder().encode(reference)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Pins the unconditional `encode` (not `encodeIfPresent`): a registry
        // written by this build always carries an explicit value for the flag.
        XCTAssertNotNil(json["autoFillEnabled"])
        XCTAssertEqual(json["autoFillEnabled"] as? Bool, true)
    }

    private func makeCloudReference() -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 10),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.webDAV.rawValue,
                    accountId: "acct-1",
                    fileId: "/vault.kdbx",
                    displayPath: "/vault.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    lastSyncedAt: nil,
                    lastSyncIssue: nil
                )
            )
        )
    }
}

private struct LegacyDatabaseReferencePayload: Codable {
    let id: UUID
    let nickname: String?
    let filename: String
    let bookmarkData: Data?
    let keyFileBookmarkData: Data?
    let keyFileFilename: String?
    let isQuickLaunch: Bool
    let lastOpenedAt: Date?
    let addedAt: Date
    let colorTag: String?
    let legacyKeychainFilename: String?
    let source: DatabaseSource
}
