import AuthenticationServices
import Foundation
import XCTest
@testable import KeeForge

final class CloudSyncCoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        super.tearDown()
    }

    func testSyncDownloadsFreshCopyWhenRemoteMetadataChanges() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 200),
                contentHash: "new-hash",
                size: 128
            )
        )
        provider.downloadedData = Data("fresh-cloud-copy".utf8)
        let progressRecorder = ProgressRecorder()

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider },
            progress: { progressRecorder.append($0) }
        )

        XCTAssertEqual(resolution.status, .downloaded)
        XCTAssertEqual(resolution.data, Data("fresh-cloud-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 1)
        XCTAssertEqual(progressRecorder.values, [1])
        XCTAssertNil(resolution.reference.cloudSyncMetadata?.lastSyncError)
        XCTAssertEqual(resolution.reference.cloudSyncMetadata?.remoteContentHash, "new-hash")
        XCTAssertNotNil(resolution.reference.cloudSyncMetadata?.lastSyncedAt)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))),
            Data("fresh-cloud-copy".utf8)
        )
    }

    func testSyncReturnsCurrentWhenRemoteMetadataMatchesCachedCopy() async throws {
        let modifiedDate = Date(timeIntervalSince1970: 200)
        let reference = makeCloudReference(
            remoteContentHash: "same-hash",
            remoteModifiedAt: modifiedDate
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-current-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: modifiedDate,
                contentHash: "same-hash",
                size: 128
            )
        )

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .current)
        XCTAssertEqual(resolution.data, Data("cached-current-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertNil(resolution.reference.cloudSyncMetadata?.lastSyncError)
        XCTAssertNotNil(resolution.reference.cloudSyncMetadata?.lastSyncedAt)
    }

    func testSyncFallsBackToCachedCopyWhenOffline() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-offline-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.networkUnavailable)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .offlineCached)
        XCTAssertEqual(resolution.data, Data("cached-offline-copy".utf8))
        XCTAssertEqual(resolution.bannerMessage, CloudSyncResolution.offlineCachedBannerMessage)
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.networkUnavailable.errorDescription
        )
    }

    func testSyncUsesDisconnectedCachedWhenProviderIsUnavailable() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-disconnected-copy".utf8), for: reference)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in nil }
        )

        XCTAssertEqual(resolution.status, .disconnectedCached)
        XCTAssertEqual(resolution.data, Data("cached-disconnected-copy".utf8))
        XCTAssertEqual(resolution.bannerMessage, CloudSyncResolution.disconnectedCachedBannerMessage)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.notAuthenticated.errorDescription
        )
    }

    func testSyncUsesDisconnectedCachedWhenAccountIsSignedOut() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-signed-out-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.authenticated = false

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .disconnectedCached)
        XCTAssertEqual(resolution.data, Data("cached-signed-out-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 0)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.notAuthenticated.errorDescription
        )
    }

    func testSyncUsesCachedCopyWithErrorForNonOfflineFailures() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-error-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.fileNotFound)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(
            resolution.status,
            .cachedWithError(CloudProviderError.fileNotFound.localizedDescription)
        )
        XCTAssertEqual(resolution.data, Data("cached-error-copy".utf8))
        XCTAssertEqual(
            resolution.bannerMessage,
            CloudProviderError.fileNotFound.localizedDescription
        )
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.fileNotFound.localizedDescription
        )
    }

    func testSyncThrowsWhenCachedFallbackIsDisabled() async {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try? DatabaseListStore.cacheDatabaseCopy(Data("cached-but-disabled".utf8), for: reference)
        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.fileNotFound)

        do {
            _ = try await CloudSyncCoordinator.syncIfNeededForOpen(
                reference: reference,
                allowCachedFallback: false,
                providerResolver: { _ in provider }
            )
            XCTFail("Expected sync to throw when cached fallback is disabled.")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeCloudReference(
        remoteContentHash: String?,
        remoteModifiedAt: Date?
    ) -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 50),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/vault.kdbx",
                    displayPath: "/Vaults/vault.kdbx",
                    remoteContentHash: remoteContentHash,
                    remoteModifiedAt: remoteModifiedAt,
                    lastSyncedAt: nil,
                    lastSyncError: nil
                )
            )
        )
    }
}

private final class MockCloudProvider: CloudProvider, @unchecked Sendable {
    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    var authenticated = true
    var metadataResult: Result<CloudFileMetadata, Error> = .failure(CloudProviderError.fileNotFound)
    var downloadedData = Data()
    private(set) var metadataCallCount = 0
    private(set) var downloadCallCount = 0
    private(set) var uploadCallCount = 0

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        XCTFail("authenticate(from:) should not be called in CloudSyncCoordinatorTests")
        throw CloudProviderError.authenticationCancelled
    }

    func isAuthenticated(accountId: String) -> Bool {
        authenticated
    }

    func signOut(accountId: String) {}

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        XCTFail("listFiles(accountId:path:query:) should not be called in CloudSyncCoordinatorTests")
        return []
    }

    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        downloadCallCount += 1
        try downloadedData.write(to: localURL)
        progress(1)
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        metadataCallCount += 1
        return try metadataResult.get()
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        uploadCallCount += 1
        progress(1)
        return CloudFileMetadata(
            modifiedDate: Date(),
            contentHash: nil,
            size: Int64(data.count),
            rev: expectedRev
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
