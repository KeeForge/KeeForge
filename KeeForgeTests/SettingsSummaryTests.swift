import SwiftUI
import XCTest
@testable import KeeForge

final class SettingsSummaryRowTests: XCTestCase {
    func testSummaryIsCappedAtTwoLinesOnlyBelowAccessibilitySizes() {
        XCTAssertEqual(SettingsSummaryRow.summaryLineLimit(for: .large), 2)
        XCTAssertEqual(SettingsSummaryRow.summaryLineLimit(for: .xxxLarge), 2)
        XCTAssertNil(SettingsSummaryRow.summaryLineLimit(for: .accessibility1))
        XCTAssertNil(SettingsSummaryRow.summaryLineLimit(for: .accessibility5))
    }
}

final class AppSettingsSummaryTests: XCTestCase {
    func testSecurityNamesTheBiometricOnlyWhenOneIsPassedIn() {
        XCTAssertEqual(
            AppSettingsSummary.security(autoUnlockBiometric: .faceID, autoLockTimeout: .oneMinute, lockOnBackground: true),
            "Face ID · Locks after 1 Minute"
        )
        XCTAssertEqual(
            AppSettingsSummary.security(autoUnlockBiometric: .touchID, autoLockTimeout: .fiveMinutes, lockOnBackground: true),
            "Touch ID · Locks after 5 Minutes"
        )
        XCTAssertEqual(
            AppSettingsSummary.security(autoUnlockBiometric: .none, autoLockTimeout: .thirtySeconds, lockOnBackground: false),
            "Locks after 30 Seconds"
        )
    }

    func testSecurityDescribesEveryAutoLockTimeout() {
        XCTAssertEqual(
            AppSettingsSummary.security(autoUnlockBiometric: .none, autoLockTimeout: .immediately, lockOnBackground: false),
            "Locks immediately"
        )
        // With no timeout, background locking is the only lock left to report.
        XCTAssertEqual(
            AppSettingsSummary.security(autoUnlockBiometric: .none, autoLockTimeout: .never, lockOnBackground: true),
            "Locks in background"
        )
        XCTAssertEqual(
            AppSettingsSummary.security(autoUnlockBiometric: .none, autoLockTimeout: .never, lockOnBackground: false),
            "No auto-lock"
        )

        for timeout in SettingsService.AutoLockTimeout.allCases {
            XCTAssertFalse(
                AppSettingsSummary.security(autoUnlockBiometric: .none, autoLockTimeout: timeout, lockOnBackground: false).isEmpty,
                "\(timeout) has no summary"
            )
        }
    }

    func testAutoFillCountsTheDatabasesThatAreIncluded() {
        let databases = [
            makeReference(autoFillEnabled: true),
            makeReference(autoFillEnabled: false),
            makeReference(autoFillEnabled: true),
        ]

        XCTAssertEqual(AppSettingsSummary.autoFill(isProviderEnabled: true, databases: databases), "On · Databases: 2 of 3")
        XCTAssertEqual(AppSettingsSummary.autoFill(isProviderEnabled: false, databases: databases), "Off · Databases: 2 of 3")
    }

    func testAutoFillSaysNothingAboutAProviderStateItDoesNotKnow() {
        XCTAssertEqual(
            AppSettingsSummary.autoFill(isProviderEnabled: nil, databases: [makeReference(autoFillEnabled: true)]),
            "Databases: 1 of 1"
        )
        XCTAssertEqual(AppSettingsSummary.autoFill(isProviderEnabled: nil, databases: []), "")
        XCTAssertEqual(AppSettingsSummary.autoFill(isProviderEnabled: true, databases: []), "On")
    }

    func testDisplayNamesTheThemeAndFaviconState() {
        XCTAssertEqual(
            AppSettingsSummary.display(appearanceMode: .system, showWebsiteIcons: true),
            "System Default · Favicons on"
        )
        XCTAssertEqual(
            AppSettingsSummary.display(appearanceMode: .dark, showWebsiteIcons: false),
            "Dark · Favicons off"
        )
    }

    func testCloudAccountsListsEachProviderOnce() {
        let accounts = [
            CloudAccount(id: "a", displayName: "first@example.com", provider: CloudProviderKind.dropbox.rawValue),
            CloudAccount(id: "b", displayName: "second@example.com", provider: CloudProviderKind.dropbox.rawValue),
            CloudAccount(id: "c", displayName: "dav.example.com", provider: CloudProviderKind.webDAV.rawValue),
        ]

        XCTAssertEqual(
            AppSettingsSummary.cloudAccounts(accounts),
            ["Dropbox", "WebDAV"].formatted(.list(type: .and, width: .narrow))
        )
        XCTAssertEqual(AppSettingsSummary.cloudAccounts([]), "None")
    }

    private func makeReference(autoFillEnabled: Bool) -> DatabaseReference {
        var reference = DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil
        )
        reference.autoFillEnabled = autoFillEnabled
        return reference
    }
}

final class DatabaseSettingsSummaryTests: XCTestCase {
    private let summary = KDBXFileSummary(
        formatVersion: .kdbx4(minor: 1),
        cipher: .chacha20,
        isCompressed: true,
        keyDerivation: .argon2id(iterations: 3, memoryBytes: 64 * 1024 * 1024, parallelism: 2)
    )

    func testHeaderAddsTheFileFactsOnceTheyAreLoaded() {
        XCTAssertEqual(DatabaseSettingsSummary.header(filename: "Personal.kdbx", fileInfo: nil), "Personal.kdbx")

        let size: Int64 = 248_000
        let info = DatabaseFileInfo(fileSizeBytes: size, modifiedAt: nil, summary: summary)
        XCTAssertEqual(
            DatabaseSettingsSummary.header(filename: "Personal.kdbx", fileInfo: info),
            "Personal.kdbx · KDBX 4.1 · \(size.formatted(.byteCount(style: .file)))"
        )

        // A file whose header could not be parsed still reports its size.
        XCTAssertEqual(
            DatabaseSettingsSummary.header(filename: "Personal.kdbx", fileInfo: DatabaseFileInfo(fileSizeBytes: size)),
            "Personal.kdbx · \(size.formatted(.byteCount(style: .file)))"
        )
    }

    func testGeneralReportsQuickLaunchAndTheEditingMode() {
        XCTAssertEqual(DatabaseSettingsSummary.general(isQuickLaunch: true, isReadOnly: false), "Quick Launch · Editing allowed")
        XCTAssertEqual(DatabaseSettingsSummary.general(isQuickLaunch: false, isReadOnly: false), "Editing allowed")
        XCTAssertEqual(DatabaseSettingsSummary.general(isQuickLaunch: true, isReadOnly: true), "Quick Launch · Read-only")
        XCTAssertEqual(DatabaseSettingsSummary.general(isQuickLaunch: false, isReadOnly: true), "Read-only")
    }

    func testAutoFillNamesTheSaveGroupOnlyWhileIncluded() {
        XCTAssertEqual(
            DatabaseSettingsSummary.autoFill(isEnabled: true, destinationGroupName: "Internet"),
            "Included · Saves to Internet"
        )
        XCTAssertEqual(DatabaseSettingsSummary.autoFill(isEnabled: true, destinationGroupName: nil), "Included")
        XCTAssertEqual(DatabaseSettingsSummary.autoFill(isEnabled: false, destinationGroupName: "Internet"), "Not included")
    }

    func testMasterKeyReportsTheRememberedKeyFileAndHardwareKey() {
        XCTAssertEqual(DatabaseSettingsSummary.masterKey(keyFileFilename: nil, usesHardwareKey: false), "No key file")
        XCTAssertEqual(DatabaseSettingsSummary.masterKey(keyFileFilename: "vault.keyx", usesHardwareKey: false), "vault.keyx")
        XCTAssertEqual(
            DatabaseSettingsSummary.masterKey(keyFileFilename: "vault.keyx", usesHardwareKey: true),
            "YubiKey · vault.keyx"
        )
        XCTAssertEqual(DatabaseSettingsSummary.masterKey(keyFileFilename: nil, usesHardwareKey: true), "YubiKey · No key file")
    }

    func testEncryptionNamesCipherAndKeyDerivation() {
        XCTAssertEqual(DatabaseSettingsSummary.encryption(summary), "ChaCha20 · Argon2id")
        XCTAssertNil(DatabaseSettingsSummary.encryption(nil))
    }

    func testCloudSyncPrefersAWarningOverTheLastSync() {
        let lastSyncedAt = Date.now.addingTimeInterval(-300)
        let healthy = makeCloudState(warningText: nil)

        XCTAssertEqual(
            DatabaseSettingsSummary.cloudSync(healthy, lastSyncedAt: lastSyncedAt),
            "WebDAV · Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))"
        )
        XCTAssertEqual(DatabaseSettingsSummary.cloudSync(healthy, lastSyncedAt: nil), "WebDAV · Healthy")
        XCTAssertEqual(
            DatabaseSettingsSummary.cloudSync(makeCloudState(warningText: "Disconnected"), lastSyncedAt: lastSyncedAt),
            "WebDAV · Disconnected"
        )
    }

    func testBackupsCountsThemAndDatesTheNewest() {
        XCTAssertEqual(DatabaseSettingsSummary.backups([]), "No backups on this device.")

        let newest = Date.now.addingTimeInterval(-7_200)
        let backups = [
            makeBackup("older", createdAt: newest.addingTimeInterval(-86_400)),
            makeBackup("newest", createdAt: newest),
            makeBackup("unparsed", createdAt: nil),
        ]
        XCTAssertEqual(
            DatabaseSettingsSummary.backups(backups),
            "3 backups · Latest: \(newest.formatted(.relative(presentation: .named)))"
        )

        XCTAssertEqual(DatabaseSettingsSummary.backups([makeBackup("only", createdAt: nil)]), "1 backup")
    }

    private func makeCloudState(warningText: String?) -> CloudRowState {
        CloudRowState(
            providerName: "WebDAV",
            isConnected: warningText == nil,
            warningText: warningText,
            displayPath: "/vault.kdbx",
            accountLabel: "dav.example.com"
        )
    }

    private func makeBackup(_ name: String, createdAt: Date?) -> DatabaseExportService.Backup {
        DatabaseExportService.Backup(url: URL(fileURLWithPath: "/backups/\(name).kdbx"), createdAt: createdAt)
    }
}
