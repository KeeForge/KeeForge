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
        XCTAssertNil(decoded.editsAcknowledgedAt)
        XCTAssertTrue(decoded.autoFillEnabled)
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
            editsAcknowledgedAt: Date(timeIntervalSince1970: 30),
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
                    lastSyncError: nil
                )
            )
        )

        let data = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(DatabaseReference.self, from: data)

        XCTAssertEqual(decoded, reference)
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
