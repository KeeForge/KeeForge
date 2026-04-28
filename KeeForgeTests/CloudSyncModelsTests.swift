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
        metadata.lastSyncError = "Offline"
        metadata.lastSyncedAt = Date(timeIntervalSinceNow: -100_000)

        XCTAssertEqual(metadata.warningText(isAuthenticated: false), "Disconnected")
    }

    func testWarningTextReturnsLastSyncErrorWhenConnected() {
        var metadata = makeCloudSyncMetadata(remoteContentHash: "hash", remoteModifiedAt: Date())
        metadata.lastSyncError = "Remote file missing"

        XCTAssertEqual(metadata.warningText(isAuthenticated: true), "Remote file missing")
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
            lastSyncError: nil
        )
    }
}
