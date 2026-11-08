import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class CloudDiscardPresentationTests: XCTestCase {
    private var reference: DatabaseReference!

    override func setUp() async throws {
        try await super.setUp()
        reference = DatabaseListStore.addCloud(
            provider: "webdav", accountId: UUID().uuidString,
            file: CloudFile(id: UUID().uuidString, name: "Discard.kdbx", path: "/Discard.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        )
    }

    override func tearDown() async throws {
        DatabaseListStore.remove(id: reference.id)
        try await super.tearDown()
    }

    func testUncertainDiscardKeepsPendingBadgeAndExplainsRetention() async throws {
        let stored = try makeConflict(uncertain: true)
        let viewModel = DatabaseListViewModel()

        await viewModel.discardConflictedPendingUploads(for: reference)

        XCTAssertEqual(viewModel.pendingUploadAlert?.kind, .message)
        XCTAssertEqual(viewModel.pendingUploadAlert?.databaseId, reference.id)
        XCTAssertEqual(viewModel.pendingUploadAlert?.title, String(localized: "Pending Change Kept"))
        XCTAssertTrue(viewModel.hasPendingUploadConflicts(for: reference))
        let retained = try XCTUnwrap(PendingUploadQueue.listMarkers(for: reference.id).first { $0.id == stored.id })
        XCTAssertEqual(retained.marker.discardRequested, true)
        XCTAssertFalse(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    func testDefinitivelyDiscardedConflictClearsBadgeWithoutRetentionAlert() async throws {
        _ = try makeConflict(uncertain: false)
        let viewModel = DatabaseListViewModel()

        await viewModel.discardConflictedPendingUploads(for: reference)

        XCTAssertNil(viewModel.pendingUploadAlert)
        XCTAssertFalse(viewModel.hasPendingUploadConflicts(for: reference))
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: reference.id).isEmpty)
        XCTAssertFalse(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    private func makeConflict(uncertain: Bool) throws -> PendingUploadQueue.StoredMarker {
        let original = Data("original encrypted bytes".utf8)
        let intended = Data("pending encrypted bytes".utf8)
        let cache = DatabaseListStore.cacheLocation(for: reference)
        try writeAtomicallyAndDurably(original, to: cache)
        return try PendingUploadQueue.withCommitLock(for: reference.id) {
            var stored = try PendingUploadQueue.prepare(reference: reference, currentData: original, intendedData: intended, cacheURL: cache)
            stored.marker.openTimeSHA512 = KDBXCrypto.sha512(intended)
            stored = try PendingUploadQueue.finalize(stored)
            stored.marker.isConflicted = true
            if uncertain { stored.marker.uploadAttemptID = UUID() }
            return try PendingUploadQueue.update(stored)
        }
    }
}
