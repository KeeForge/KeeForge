import XCTest
@testable import KeeForge

final class DatabaseRowStatusSummaryTests: XCTestCase {
    private func status(
        hasAccessIssue: Bool = false,
        cloudWarning: String? = nil,
        isCloud: Bool = false,
        pending: Int = 0,
        conflicts: Int = 0,
        documentsFileMissing: Bool = false
    ) -> DatabaseRowStatus {
        DatabaseRowStatus(
            hasStoredKey: false,
            hasAccessIssue: hasAccessIssue,
            cloudState: isCloud || cloudWarning != nil
                ? CloudRowState(
                    providerName: "WebDAV",
                    isConnected: true,
                    warningText: cloudWarning,
                    displayPath: "/vault.kdbx",
                    accountLabel: "account"
                )
                : nil,
            pendingUploadCount: pending,
            pendingUploadConflictCount: conflicts,
            isDocumentsFileMissing: documentsFileMissing
        )
    }

    func testQuietDatabaseHasNoBadgesOrNotices() {
        let summary = DatabaseRowStatusSummary(isReadOnly: false, isQuickLaunch: false, status: status())
        XCTAssertEqual(summary.badges, [])
        XCTAssertEqual(summary.notices, [])
    }

    func testBadgesFollowNameInFixedOrder() {
        let summary = DatabaseRowStatusSummary(isReadOnly: true, isQuickLaunch: true, status: status(pending: 2))
        XCTAssertEqual(summary.badges, [.readOnly, .quickLaunch])
    }

    func testPendingUploadsAreCountedInWords() {
        let summary = DatabaseRowStatusSummary(isReadOnly: false, isQuickLaunch: false, status: status(isCloud: true, pending: 1))
        XCTAssertEqual(summary.notices, [.waitingToUpload(1)])
        XCTAssertFalse(summary.notices[0].text.lowercased().hasPrefix("pending"))
    }

    func testConflictReplacesWaitingAndCloudWarning() {
        let summary = DatabaseRowStatusSummary(
            isReadOnly: false,
            isQuickLaunch: false,
            status: status(cloudWarning: "Signed out", pending: 3, conflicts: 1)
        )
        XCTAssertEqual(summary.badges, [])
        XCTAssertEqual(summary.notices, [.uploadConflicts(1)])
    }

    func testCloudWarningFollowsWaitingUploads() {
        let summary = DatabaseRowStatusSummary(
            isReadOnly: false,
            isQuickLaunch: false,
            status: status(cloudWarning: "Signed out", pending: 1)
        )
        XCTAssertEqual(summary.notices, [.waitingToUpload(1), .cloudWarning("Signed out")])
    }

    func testAccessIssueNamesWhatIsUnavailable() {
        let local = DatabaseRowStatusSummary(isReadOnly: false, isQuickLaunch: false, status: status(hasAccessIssue: true))
        XCTAssertEqual(local.notices, [.fileUnavailable])

        let cloud = DatabaseRowStatusSummary(isReadOnly: false, isQuickLaunch: false, status: status(hasAccessIssue: true, isCloud: true))
        XCTAssertEqual(cloud.notices, [.cacheUnavailable])
    }

    func testMissingDocumentsFileOutranksAccessIssue() {
        let summary = DatabaseRowStatusSummary(
            isReadOnly: false,
            isQuickLaunch: false,
            status: status(hasAccessIssue: true, documentsFileMissing: true)
        )
        XCTAssertEqual(summary.notices, [.documentsFileMissing])
    }
}
