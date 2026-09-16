import XCTest
@testable import KeeForge

final class CloudSyncModelsTests: XCTestCase {
    func testCloudProviderKindDropboxMetadata() {
        XCTAssertEqual(CloudProviderKind.dropbox.id, "dropbox")
        XCTAssertEqual(CloudProviderKind.dropbox.displayName, "Dropbox")
        XCTAssertEqual(CloudProviderKind.dropbox.iconName, "shippingbox.fill")
    }

    func testCloudProviderKindOneDriveMetadata() {
        XCTAssertEqual(CloudProviderKind.oneDrive.id, "onedrive")
        XCTAssertEqual(CloudProviderKind.oneDrive.displayName, "OneDrive")
        XCTAssertEqual(CloudProviderKind.oneDrive.iconName, "cloud.fill")
    }

    func testCloudAccountProviderKindResolvesKnownProvider() {
        let account = CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: "dropbox")
        let oneDriveAccount = CloudAccount(id: "acct-2", displayName: "alex@example.com", provider: "onedrive")
        let unknown = CloudAccount(id: "acct-2", displayName: "Unknown", provider: "other")

        XCTAssertEqual(account.providerKind, .dropbox)
        XCTAssertEqual(oneDriveAccount.providerKind, .oneDrive)
        XCTAssertNil(unknown.providerKind)
    }

    func testRequiresDownloadWhenCacheIsMissing() {
        let remote = makeRemoteMetadata(contentHash: "remote-hash", modifiedDate: Date(timeIntervalSince1970: 200))
        let cached = makeCloudSyncMetadata(remoteContentHash: "remote-hash", remoteModifiedAt: Date(timeIntervalSince1970: 200))

        XCTAssertTrue(remote.requiresDownload(comparedTo: cached, cacheExists: false))
    }

    func testRequiresDownloadWhenContentHashDiffers() {
        let remote = makeRemoteMetadata(contentHash: "new-hash", modifiedDate: Date(timeIntervalSince1970: 300))
        let cached = makeCloudSyncMetadata(remoteContentHash: "old-hash", remoteModifiedAt: Date(timeIntervalSince1970: 200))

        XCTAssertTrue(remote.requiresDownload(comparedTo: cached, cacheExists: true))
    }

    func testDoesNotRequireDownloadWhenContentHashMatches() {
        let remote = makeRemoteMetadata(contentHash: "same-hash", modifiedDate: Date(timeIntervalSince1970: 300))
        let cached = makeCloudSyncMetadata(remoteContentHash: "same-hash", remoteModifiedAt: Date(timeIntervalSince1970: 100))

        XCTAssertFalse(remote.requiresDownload(comparedTo: cached, cacheExists: true))
    }

    func testRequiresDownloadWhenRevisionDiffersWithoutHash() {
        let remote = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 300),
            contentHash: nil,
            size: 128,
            rev: "rev-B"
        )
        var cached = makeCloudSyncMetadata(remoteContentHash: nil, remoteModifiedAt: Date(timeIntervalSince1970: 300))
        cached.remoteRev = "rev-A"

        XCTAssertTrue(remote.requiresDownload(comparedTo: cached, cacheExists: true))
    }

    func testRequiresDownloadFallsBackToRevWhenCachedHashMissing() {
        // A remote hash with no cached counterpart cannot be compared; the
        // decision falls through to the rev.
        let remote = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 300),
            contentHash: "quickXor:remote-hash",
            size: 128,
            rev: "rev-A"
        )
        var cached = makeCloudSyncMetadata(remoteContentHash: nil, remoteModifiedAt: Date(timeIntervalSince1970: 100))
        cached.remoteRev = "rev-A"

        XCTAssertFalse(remote.requiresDownload(comparedTo: cached, cacheExists: true))

        cached.remoteRev = "rev-B"
        XCTAssertTrue(remote.requiresDownload(comparedTo: cached, cacheExists: true))
    }

    func testRequiresDownloadWhenHashesUseDifferentTaggedAlgorithms() {
        // Algorithm-tagged tokens (OneDrive) can never compare equal across
        // algorithms, so a SHA-1 from one response and a QuickXor from another
        // read as a change instead of silently comparing raw values.
        let remote = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 300),
            contentHash: "quickXor:AAAA",
            size: 128,
            rev: "rev-A"
        )
        var cached = makeCloudSyncMetadata(
            remoteContentHash: "sha1:BBBB",
            remoteModifiedAt: Date(timeIntervalSince1970: 300)
        )
        cached.remoteRev = "rev-A"

        XCTAssertTrue(remote.requiresDownload(comparedTo: cached, cacheExists: true))
    }

    func testRequiresDownloadWhenCachedModifiedDateMissingAndNoHash() {
        let remote = makeRemoteMetadata(contentHash: nil, modifiedDate: Date(timeIntervalSince1970: 300))
        let cached = makeCloudSyncMetadata(remoteContentHash: nil, remoteModifiedAt: nil)

        XCTAssertTrue(remote.requiresDownload(comparedTo: cached, cacheExists: true))
    }

    func testDoesNotRequireDownloadWhenModifiedDateMatchesWithoutHash() {
        let modifiedDate = Date(timeIntervalSince1970: 300)
        let remote = makeRemoteMetadata(contentHash: nil, modifiedDate: modifiedDate)
        let cached = makeCloudSyncMetadata(remoteContentHash: nil, remoteModifiedAt: modifiedDate)

        XCTAssertFalse(remote.requiresDownload(comparedTo: cached, cacheExists: true))
    }

    func testWarningTextPrefersDisconnectedState() {
        var metadata = makeCloudSyncMetadata(remoteContentHash: "hash", remoteModifiedAt: Date())
        metadata.lastSyncIssue = .unknown("Offline")
        metadata.lastSyncedAt = Date(timeIntervalSinceNow: -100_000)

        XCTAssertEqual(metadata.warningText(isAuthenticated: false), "Disconnected")
    }

    func testWarningTextReturnsLastSyncIssueWhenConnected() {
        var metadata = makeCloudSyncMetadata(remoteContentHash: "hash", remoteModifiedAt: Date())
        metadata.lastSyncIssue = .fileNotFound

        XCTAssertEqual(
            metadata.warningText(isAuthenticated: true),
            CloudSyncIssue.fileNotFound.localizedDescription
        )
        XCTAssertTrue(metadata.isStale)
    }

    func testWarningTextReturnsStaleSyncMessageWhenOlderThan24Hours() {
        var metadata = makeCloudSyncMetadata(remoteContentHash: "hash", remoteModifiedAt: Date())
        metadata.lastSyncedAt = Date(timeIntervalSinceNow: -90_000)

        XCTAssertEqual(metadata.warningText(isAuthenticated: true), "Sync older than 24h")
    }

    func testWarningTextReturnsNilWhenHealthy() {
        var metadata = makeCloudSyncMetadata(remoteContentHash: "hash", remoteModifiedAt: Date())
        metadata.lastSyncedAt = Date()

        XCTAssertNil(metadata.warningText(isAuthenticated: true))
        XCTAssertFalse(metadata.isStale)
    }

    // MARK: - CloudSyncIssue

    func testCloudSyncIssueRendersEveryCaseFromTheCatalog() {
        let cases: [CloudSyncIssue] = [
            .invalidConfiguration, .authenticationCancelled, .notAuthenticated,
            .networkUnavailable, .fileNotFound, .conflict, .writeScopeRequired,
            .rateLimited, .serviceUnavailable, .insufficientSpace,
            .permissionDenied, .invalidName,
        ]

        for issue in cases {
            XCTAssertFalse(
                issue.localizedDescription.isEmpty,
                "\(issue) renders an empty string"
            )
        }
        XCTAssertEqual(CloudSyncIssue.unknown("boom").localizedDescription, "boom")
    }

    func testCloudSyncIssueRoundTripsThroughCoding() throws {
        let cases: [CloudSyncIssue] = [
            .invalidConfiguration, .authenticationCancelled, .notAuthenticated,
            .networkUnavailable, .fileNotFound, .conflict, .writeScopeRequired,
            .rateLimited, .serviceUnavailable, .insufficientSpace,
            .permissionDenied, .invalidName, .unknown("server said no"),
        ]

        for issue in cases {
            let encoded = try JSONEncoder().encode(issue)
            let decoded = try JSONDecoder().decode(CloudSyncIssue.self, from: encoded)
            XCTAssertEqual(decoded, issue)
        }
    }

    /// The discriminators are on disk in every user's database list. Pinning
    /// them here makes a rename fail as a test, not as a silent downgrade to
    /// `unknown` on the next launch.
    func testCloudSyncIssueEncodesStableCodes() throws {
        let encoded = try JSONEncoder().encode(CloudSyncIssue.conflict)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(json["code"] as? String, "conflict")
        XCTAssertNil(json["message"])
    }

    func testCloudSyncIssueDecodesUnrecognizedCodeAsUnknownRatherThanThrowing() throws {
        // DatabaseListStore decodes the stored list all-or-nothing, so a throw
        // here would empty the user's database list.
        let json = Data(#"{"code":"somethingNewer","message":"from a later build"}"#.utf8)

        let decoded = try JSONDecoder().decode(CloudSyncIssue.self, from: json)

        XCTAssertEqual(decoded, .unknown("from a later build"))
    }

    /// Metadata written before the issue code existed carried a
    /// `lastSyncError` sentence. It must decode — dropping the stale warning
    /// is fine, emptying the database list is not — and the next sync
    /// re-derives the issue.
    func testCloudSyncMetadataDecodesLegacyLastSyncErrorAsNoIssue() throws {
        let json = Data("""
        {
          "provider" : "dropbox",
          "accountId" : "acct-1",
          "fileId" : "/Vaults/test.kdbx",
          "displayPath" : "/Vaults/test.kdbx",
          "lastSyncError" : "This database changed in the cloud. Reload before saving again."
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(CloudSyncMetadata.self, from: json)

        XCTAssertEqual(decoded.fileId, "/Vaults/test.kdbx")
        XCTAssertNil(decoded.lastSyncIssue)
        XCTAssertFalse(decoded.isStale)
    }

    /// The point of storing a code: the warning is rendered when it is read,
    /// so it follows the reader's language instead of the one in force when
    /// the sync failed.
    func testWarningTextRendersTheIssueRatherThanAStoredSentence() {
        var metadata = makeCloudSyncMetadata(remoteContentHash: "hash", remoteModifiedAt: Date())
        metadata.lastSyncIssue = .conflict

        XCTAssertEqual(
            metadata.warningText(isAuthenticated: true),
            CloudSyncIssue.conflict.localizedDescription
        )
    }

    private func makeRemoteMetadata(contentHash: String?, modifiedDate: Date) -> CloudFileMetadata {
        CloudFileMetadata(modifiedDate: modifiedDate, contentHash: contentHash, size: 128)
    }

    private func makeCloudSyncMetadata(remoteContentHash: String?, remoteModifiedAt: Date?) -> CloudSyncMetadata {
        CloudSyncMetadata(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            fileId: "/Vaults/test.kdbx",
            displayPath: "/Vaults/test.kdbx",
            remoteContentHash: remoteContentHash,
            remoteModifiedAt: remoteModifiedAt,
            lastSyncedAt: nil,
            lastSyncIssue: nil
        )
    }
}
