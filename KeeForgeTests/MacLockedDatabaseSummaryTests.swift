#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class MacLockedDatabaseSummaryTests: XCTestCase {
    func testLocalSublineNamesTheFileThisMacAndLastOpened() {
        let reference = MacLockedPageFixtures.reference(filename: "Personal.kdbx", keyFile: "personal.keyx")

        let summary = MacLockedDatabaseSummary(reference: reference, lastOpened: "Last opened 2 hours ago")

        let thisMac = String(localized: "On This Mac")
        XCTAssertEqual(summary.name, "Personal")
        XCTAssertEqual(summary.subline, "Personal.kdbx · \(thisMac) · Last opened 2 hours ago")
        XCTAssertEqual(summary.fileAndStorage, "Personal.kdbx · \(thisMac)")
        XCTAssertEqual(summary.recoverySubtitle, "Personal · Personal.kdbx · \(thisMac)")
        XCTAssertEqual(summary.keyFileName, "personal.keyx")
    }

    func testServerSublinesNameTheProviderAndNeverItsAddressOrPath() {
        for provider in [CloudProviderKind.webDAV, .ftp] {
            var reference = MacLockedPageFixtures.reference(filename: "work-vault.kdbx", provider: provider)
            reference.nickname = "Work Vault"

            let summary = MacLockedDatabaseSummary(reference: reference, lastOpened: "Last opened yesterday")

            XCTAssertEqual(summary.name, "Work Vault")
            XCTAssertEqual(summary.subline, "work-vault.kdbx · \(provider.displayName) · Last opened yesterday")
            XCTAssertEqual(summary.recoverySubtitle, "Work Vault · work-vault.kdbx · \(provider.displayName)")
            for text in [summary.subline, summary.fileAndStorage, summary.recoverySubtitle] {
                XCTAssertFalse(text.contains(MacLockedPageFixtures.serverPath), "\(provider): \(text)")
                XCTAssertFalse(text.contains("account"), "\(provider): \(text)")
            }
            XCTAssertNil(summary.keyFileName)
        }
    }

    func testSublineWithoutLastOpenedStopsAtTheStorage() {
        let reference = MacLockedPageFixtures.reference(filename: "work-vault.kdbx", provider: .webDAV)

        let summary = MacLockedDatabaseSummary(reference: reference, lastOpened: nil)

        XCTAssertEqual(summary.subline, "work-vault.kdbx · WebDAV")
        XCTAssertEqual(summary.subline, summary.fileAndStorage)
    }

    func testTheDatabasesWindowSharesTheFileAndStorageLine() {
        let reference = MacLockedPageFixtures.reference(filename: "work-vault.kdbx", provider: .ftp)

        let row = MacDatabasesLauncherViewModel.row(for: reference,
            status: DatabaseRowStatus(hasStoredKey: false, hasAccessIssue: false, cloudState: nil),
            isUnlocked: false, lastOpened: nil)

        XCTAssertEqual(row.subtitle, MacLockedDatabaseSummary(reference: reference, lastOpened: nil).fileAndStorage)
    }
}

enum MacLockedPageFixtures {
    static let serverPath = "/private/vaults/work-vault.kdbx"

    static func reference(
        filename: String,
        provider: CloudProviderKind? = nil,
        keyFile: String? = nil
    ) -> DatabaseReference {
        var reference = DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: filename,
            bookmarkData: provider == nil ? Data([1]) : nil,
            keyFileBookmarkData: nil,
            keyFileFilename: keyFile,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil
        )
        if let provider {
            reference.source = .cloud(CloudSyncMetadata(provider: provider.rawValue, accountId: "account",
                fileId: serverPath, displayPath: serverPath, remoteContentHash: nil, remoteModifiedAt: nil,
                remoteRev: nil, lastSyncedAt: nil, lastSyncIssue: nil))
        }
        return reference
    }
}
#endif
