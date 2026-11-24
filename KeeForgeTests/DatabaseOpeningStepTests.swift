import XCTest
@testable import KeeForge

/// The steps the iPhone and iPad opening screen shows.
@MainActor
final class DatabaseOpeningStepTests: XCTestCase {
    private func reference(_ filename: String, isCloud: Bool = false) -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: filename,
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: isCloud
                ? .cloud(
                    CloudSyncMetadata(
                        provider: CloudProviderKind.dropbox.rawValue,
                        accountId: "account",
                        fileId: "/\(filename)",
                        displayPath: "/\(filename)",
                        remoteContentHash: nil,
                        remoteModifiedAt: nil,
                        lastSyncedAt: nil,
                        lastSyncIssue: nil
                    )
                )
                : .local
        )
    }

    func testALocalDatabaseOpensStraightIntoDecrypting() {
        let viewModel = DatabaseViewModel(databaseReference: reference("local.kdbx"))
        XCTAssertEqual(viewModel.openingStep, .decrypting)
    }

    func testACloudDatabaseSyncsBeforeItDecrypts() {
        let viewModel = DatabaseViewModel(databaseReference: reference("cloud.kdbx", isCloud: true))
        XCTAssertEqual(viewModel.openingStep, .syncing)
    }

    func testLocalStepsStartAtDecrypting() {
        let steps = DatabaseOpeningSteps.make(step: .decrypting, isCloudBacked: false, provider: nil, progress: nil,
                                              syncReachedCloud: false)

        XCTAssertEqual(steps, [
            .init(title: String(localized: "Decrypt Database"), state: .current, detail: nil),
            .init(title: String(localized: "Open Database"), state: .upcoming, detail: nil),
        ])
    }

    func testCloudStepsShowTheSyncProgressWhileSyncing() {
        let steps = DatabaseOpeningSteps.make(step: .syncing, isCloudBacked: true, provider: .dropbox, progress: 0.5,
                                              syncReachedCloud: false)

        XCTAssertEqual(steps.map(\.state), [.current, .upcoming, .upcoming])
        XCTAssertEqual(steps.first?.title, String(localized: "Sync with \(CloudProviderKind.dropbox.displayName)"))
        XCTAssertEqual(steps.first?.detail, 0.5.formatted(.percent.precision(.fractionLength(0))))
    }

    func testCloudStepsMarkTheSyncDoneOnceDecrypting() {
        let steps = DatabaseOpeningSteps.make(step: .decrypting, isCloudBacked: true, provider: nil, progress: 0.5,
                                              syncReachedCloud: true)

        XCTAssertEqual(steps.map(\.state), [.done, .current, .upcoming])
        XCTAssertEqual(steps.first?.title, String(localized: "Sync with \(String(localized: "cloud"))"))
        XCTAssertNil(steps.first?.detail)
    }

    /// Sync on open off, offline or signed out: the open used the cached copy.
    func testCloudStepsMarkTheSyncSkippedWhenTheOpenDidNotReachTheProvider() {
        let steps = DatabaseOpeningSteps.make(step: .decrypting, isCloudBacked: true, provider: .webDAV, progress: nil,
                                              syncReachedCloud: false)

        XCTAssertEqual(steps.map(\.state), [.skipped, .current, .upcoming])
        XCTAssertEqual(steps.first?.title, String(localized: "Sync with \(CloudProviderKind.webDAV.displayName)"))
        XCTAssertNil(steps.first?.detail)
    }
}
