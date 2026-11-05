import XCTest
@testable import KeeForge

/// The iPhone and iPad database overview: which database gets the spotlight
/// card, what each card and tile says, and the steps the opening screen shows.
@MainActor
final class DatabaseOverviewTests: XCTestCase {
    private func reference(
        _ filename: String,
        isQuickLaunch: Bool = false,
        lastOpenedAt: Date? = nil,
        isReadOnly: Bool = false,
        lastSyncedAt: Date? = nil,
        isCloud: Bool = false
    ) -> DatabaseReference {
        var reference = DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: filename,
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: isQuickLaunch,
            lastOpenedAt: lastOpenedAt,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: isCloud || lastSyncedAt != nil
                ? .cloud(
                    CloudSyncMetadata(
                        provider: CloudProviderKind.dropbox.rawValue,
                        accountId: "account",
                        fileId: "/\(filename)",
                        displayPath: "/\(filename)",
                        remoteContentHash: nil,
                        remoteModifiedAt: nil,
                        lastSyncedAt: lastSyncedAt,
                        lastSyncIssue: nil
                    )
                )
                : .local
        )
        reference.isReadOnly = isReadOnly
        return reference
    }

    private func status(pending: Int = 0, documentsFileMissing: Bool = false) -> DatabaseRowStatus {
        DatabaseRowStatus(
            hasStoredKey: false,
            hasAccessIssue: false,
            cloudState: nil,
            pendingUploadCount: pending,
            isDocumentsFileMissing: documentsFileMissing
        )
    }

    // MARK: Spotlight

    func testQuickLaunchDatabaseGetsTheSpotlightOverTheOneOpenedLast() {
        let recent = reference("recent.kdbx", lastOpenedAt: Date(timeIntervalSince1970: 200))
        let quickLaunch = reference("quick.kdbx", isQuickLaunch: true, lastOpenedAt: Date(timeIntervalSince1970: 100))
        let spotlight = DatabaseListViewModel.spotlightDatabase(in: [recent, quickLaunch], showsUsageStats: true)
        XCTAssertEqual(spotlight?.id, quickLaunch.id)
    }

    func testWithoutQuickLaunchTheDatabaseOpenedLastGetsTheSpotlight() {
        let first = reference("first.kdbx", lastOpenedAt: Date(timeIntervalSince1970: 100))
        let never = reference("never.kdbx")
        let recent = reference("recent.kdbx", lastOpenedAt: Date(timeIntervalSince1970: 300))
        let spotlight = DatabaseListViewModel.spotlightDatabase(in: [first, never, recent], showsUsageStats: true)
        XCTAssertEqual(spotlight?.id, recent.id)
    }

    /// With usage stats hidden, picking by last opened would reveal the
    /// activity the setting hides, so the user's order decides.
    func testHiddenUsageStatsLeaveTheSpotlightToTheListOrder() {
        let first = reference("first.kdbx", lastOpenedAt: Date(timeIntervalSince1970: 100))
        let recent = reference("recent.kdbx", lastOpenedAt: Date(timeIntervalSince1970: 300))
        let spotlight = DatabaseListViewModel.spotlightDatabase(in: [first, recent], showsUsageStats: false)
        XCTAssertEqual(spotlight?.id, first.id)
        XCTAssertNil(DatabaseListViewModel.spotlightDatabase(in: [], showsUsageStats: true))
    }

    // MARK: Status line

    func testANoticeOutranksReadOnlyAndTheLastSync() throws {
        let cloud = reference("work.kdbx", isReadOnly: true, lastSyncedAt: Date(timeIntervalSinceNow: -60))
        let line = try XCTUnwrap(DatabaseStatusLine(reference: cloud, status: status(pending: 1), lastOpenedDescription: "Last opened today"))
        XCTAssertTrue(line.needsAttention)
        XCTAssertEqual(line.text, DatabaseRowStatusSummary.Notice.waitingToUpload(1).text)
    }

    func testReadOnlyOutranksTheLastSync() throws {
        let cloud = reference("archive.kdbx", isReadOnly: true, lastSyncedAt: Date(timeIntervalSinceNow: -60))
        let line = try XCTUnwrap(DatabaseStatusLine(reference: cloud, status: status(), lastOpenedDescription: nil))
        XCTAssertFalse(line.needsAttention)
        XCTAssertEqual(line.systemImage, "lock")
    }

    func testACloudDatabaseSaysWhenItLastSyncedAndALocalOneWhenItWasOpened() throws {
        let cloud = reference("family.kdbx", lastSyncedAt: Date(timeIntervalSinceNow: -60))
        let cloudLine = try XCTUnwrap(DatabaseStatusLine(reference: cloud, status: status(), lastOpenedDescription: "Last opened today"))
        XCTAssertEqual(cloudLine.systemImage, "icloud")

        let local = reference("personal.kdbx")
        let localLine = try XCTUnwrap(DatabaseStatusLine(reference: local, status: status(), lastOpenedDescription: "Last opened today"))
        XCTAssertEqual(localLine.text, "Last opened today")
        XCTAssertEqual(localLine.accessibilityIdentifier, "database-row.last-opened")

        XCTAssertNil(DatabaseStatusLine(reference: local, status: status(), lastOpenedDescription: nil))
    }

    func testAMissingDocumentsFileKeepsTheIdentifierTheListTestsFind() throws {
        let local = reference("gone.kdbx")
        let line = try XCTUnwrap(DatabaseStatusLine(reference: local, status: status(documentsFileMissing: true), lastOpenedDescription: nil))
        XCTAssertTrue(line.needsAttention)
        XCTAssertEqual(line.accessibilityIdentifier, "database-row.documents-file-missing")
    }

    // MARK: Opening steps

    func testALocalDatabaseOpensStraightIntoDecrypting() {
        let viewModel = DatabaseViewModel(databaseReference: reference("local.kdbx"))
        XCTAssertEqual(viewModel.openingStep, .decrypting)
    }

    func testACloudDatabaseSyncsBeforeItDecrypts() {
        let viewModel = DatabaseViewModel(databaseReference: reference("cloud.kdbx", isCloud: true))
        XCTAssertEqual(viewModel.openingStep, .syncing)
    }
}
