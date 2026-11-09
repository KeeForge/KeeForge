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
}
