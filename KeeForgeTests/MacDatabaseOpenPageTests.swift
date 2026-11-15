#if os(macOS)
import XCTest
import KDBXKit
@testable import KeeForge

@MainActor
final class MacDatabaseOpenPageTests: XCTestCase {
    private typealias Page = MacDatabaseOpenPage

    private let local = MacLockedPageFixtures.reference(filename: "archive-2019.kdbx")
    private let webDAV = MacLockedPageFixtures.reference(filename: "work-vault.kdbx", provider: .webDAV)
    private let ftp = MacLockedPageFixtures.reference(filename: "ftp-vault.kdbx", provider: .ftp)

    // MARK: - Form or recovery

    func testFailuresTheFormCanFixShowTheFormWithACard() {
        let formCodes: [(String, DatabaseOpenFailure.Category)] = [
            ("auth.invalid_credentials", .authentication),
            ("auth.locked_out", .authentication),
            ("biometric.authentication_failed", .biometric),
            ("biometric.unavailable", .biometric),
            ("biometric.stored_key_unavailable", .biometric),
            ("key_file.hash_mismatch", .fileAccess),
            ("key_file.invalid_xml_data", .fileAccess),
            ("hardware_key.timeout", .hardwareKey),
        ]
        for (code, category) in formCodes {
            let failure = failure(code, category)

            let page = make(.error(failure), reference: local)

            XCTAssertEqual(page, .form(card: Page.FailureCard(title: failure.title, summary: failure.summary, code: code),
                footer: nil), code)
        }
    }

    func testFailuresAnotherPasswordCannotFixShowARecoveryPage() {
        let recoveryCodes: [(String, DatabaseOpenFailure.Category, Page.RecoverySymbol)] = [
            ("file.not_found", .fileAccess, .missingFile),
            ("file.in_recently_deleted", .fileAccess, .missingFile),
            ("file.permission_denied", .fileAccess, .fileAccess),
            ("file.read_failed", .fileAccess, .fileAccess),
            ("file.read_timeout", .fileAccess, .server),
            ("format.unsupported_version", .unsupportedFormat, .unsupportedFormat),
            ("open.kdf_resource_limit", .unsupportedFormat, .unsupportedFormat),
            ("open.parse_failed", .unexpected, .unexpected),
            ("open.crypto_failed", .unexpected, .unexpected),
            ("cloud.not_authenticated", .cloud, .account),
            ("cloud.write_scope_required", .cloud, .account),
            ("cloud.network_unavailable", .cloud, .server),
            ("cloud.service_unavailable", .cloud, .server),
            ("cloud.file_not_found", .cloud, .missingFile),
            ("cloud.unexpected", .cloud, .unexpected),
        ]
        for (code, category, symbol) in recoveryCodes {
            let failure = failure(code, category)
            let reference = code.hasPrefix("cloud.") ? webDAV : local

            guard case .recovery(let recovery)? = make(.error(failure), reference: reference) else {
                XCTFail("\(code) should show a recovery page")
                continue
            }

            XCTAssertEqual(recovery.symbol, symbol, code)
            XCTAssertEqual(recovery.title, failure.title, code)
            XCTAssertEqual(recovery.summary, failure.summary, code)
            XCTAssertEqual(recovery.errorCode, code)
            XCTAssertEqual(recovery.subtitle,
                MacLockedDatabaseSummary(reference: reference, lastOpened: nil).recoverySubtitle, code)
        }
    }

    func testRealClassifiedFailuresLandOnTheirPages() {
        let wrongKey = DatabaseOpenFailure.classify(KDBXCrypto.CryptoError.hmacMismatch, isCloudBacked: false)
        let missing = DatabaseOpenFailure.classify(CocoaError(.fileReadNoSuchFile), isCloudBacked: false)

        guard case .form(let card?, _)? = make(.error(wrongKey), reference: local) else {
            return XCTFail("A wrong key keeps the form")
        }
        XCTAssertEqual(card.code, wrongKey.errorCode)
        guard case .recovery(let recovery)? = make(.error(missing), reference: local, canRelink: true) else {
            return XCTFail("A missing file is a recovery page")
        }
        XCTAssertEqual(recovery.errorCode, "file.not_found")
        XCTAssertEqual(recovery.actions, [.locateDatabaseFile, .tryAgain, .removeFromList])
    }

    func testWrongCredentialsAfterAnUnverifiedLocateKeepLocateOnTheCard() {
        let wrongKey = failure("auth.invalid_credentials", .authentication)

        guard case .form(let card?, _)? = make(.error(wrongKey), reference: local, canRelink: true) else {
            return XCTFail("A wrong key keeps the form")
        }
        XCTAssertTrue(card.offersLocate, "The located file may be the wrong one")

        guard case .form(let plain?, _)? = make(.error(wrongKey), reference: local, canRelink: false) else {
            return XCTFail("A wrong key keeps the form")
        }
        XCTAssertFalse(plain.offersLocate)
    }

    // MARK: - Recovery actions

    func testLocateIsOfferedOnlyWhenTheFailureCanBeRelinked() {
        let missing = failure("file.not_found", .fileAccess)

        XCTAssertEqual(recoveryActions(missing, reference: local, canRelink: true),
            [.locateDatabaseFile, .tryAgain, .removeFromList])
        XCTAssertEqual(recoveryActions(missing, reference: local, canRelink: false), [.tryAgain, .removeFromList])
    }

    func testRemoveFromListIsOfferedForLocalAndServerReferences() {
        for (reference, failure) in [(local, failure("file.read_timeout", .fileAccess)),
                                     (webDAV, failure("cloud.network_unavailable", .cloud)),
                                     (ftp, failure("cloud.file_not_found", .cloud))] {
            XCTAssertEqual(recoveryActions(failure, reference: reference).last, .removeFromList, failure.errorCode)
        }
    }

    func testReconnectIsOfferedForTheTwoCloudSignInCodes() {
        for code in ["cloud.not_authenticated", "cloud.write_scope_required"] {
            XCTAssertEqual(recoveryActions(failure(code, .cloud), reference: webDAV),
                [.reconnect(.webDAV), .tryAgain, .removeFromList], code)
            XCTAssertEqual(recoveryActions(failure(code, .cloud), reference: ftp),
                [.reconnect(.ftp), .tryAgain, .removeFromList], code)
        }
        for code in ["cloud.network_unavailable", "cloud.authentication_cancelled", "cloud.service_unavailable"] {
            XCTAssertFalse(recoveryActions(failure(code, .cloud), reference: webDAV).contains(.reconnect(.webDAV)), code)
        }
    }

    // MARK: - Locked form and footer

    func testLockedShowsTheFormOrUnavailableWithoutASavedFile() {
        XCTAssertEqual(make(.locked, reference: local), .form(card: nil, footer: nil))
        XCTAssertEqual(make(.locked, reference: local, hasSavedFile: false), .unavailable)
        XCTAssertNil(make(.unlocked, reference: local))
    }

    func testFooterAppearsOnlyAfterAnInactivityLock() {
        let fiveMinutes = String(localized: "Locked automatically after 5 minutes of inactivity")
        XCTAssertEqual(make(.locked, reference: local, lastLockCause: .inactivity(.fiveMinutes)),
            .form(card: nil, footer: fiveMinutes))
        XCTAssertEqual(Page.footer(for: .inactivity(.thirtySeconds)),
            String(localized: "Locked automatically after 30 seconds of inactivity"))
        XCTAssertEqual(Page.footer(for: .inactivity(.oneMinute)),
            String(localized: "Locked automatically after 1 minute of inactivity"))

        for cause: DatabaseViewModel.LockCause? in [nil, .manual, .background, .system, .inactivity(.immediately),
                                                    .inactivity(.never)] {
            XCTAssertEqual(make(.locked, reference: local, lastLockCause: cause), .form(card: nil, footer: nil),
                String(describing: cause))
        }
    }

    func testFooterStaysUnderTheCardAfterAWrongAttempt() {
        let wrongKey = failure("auth.invalid_credentials", .authentication)
        guard case .form(_?, let footer)? = make(.error(wrongKey), reference: local,
                                                 lastLockCause: .inactivity(.fiveMinutes)) else {
            return XCTFail("A wrong key keeps the form")
        }
        XCTAssertEqual(footer, String(localized: "Locked automatically after 5 minutes of inactivity"))
        guard case .recovery? = make(.error(failure("file.not_found", .fileAccess)), reference: local,
                                     lastLockCause: .inactivity(.fiveMinutes)) else {
            return XCTFail("A missing file is a recovery page")
        }
    }

    // MARK: - Opening

    func testLocalOpeningListsDecryptThenOpen() {
        let progress = Page.OpeningProgress(step: .decrypting, syncProgress: nil,
            status: "Decrypting your database securely...", canCancel: true)

        XCTAssertEqual(make(.unlocking, reference: local, opening: progress), .opening(Page.Opening(
            steps: [
                DatabaseOpeningSteps.Step(title: String(localized: "Decrypt Database"), state: .current, detail: nil),
                DatabaseOpeningSteps.Step(title: String(localized: "Open Database"), state: .upcoming, detail: nil),
            ],
            status: "Decrypting your database securely...",
            canCancel: true
        )))
    }

    func testCloudOpeningSyncsFirstAndCarriesWhetherItCanBeCancelled() {
        let syncing = Page.OpeningProgress(step: .syncing, syncProgress: 0.4, status: "Syncing with WebDAV...",
            canCancel: false)

        guard case .opening(let opening)? = make(.unlocking, reference: webDAV, opening: syncing) else {
            return XCTFail("An open in progress shows the opening page")
        }
        XCTAssertEqual(opening.steps, DatabaseOpeningSteps.make(step: .syncing, isCloudBacked: true, provider: .webDAV,
            progress: 0.4))
        XCTAssertEqual(opening.steps.map(\.state), [.current, .upcoming, .upcoming])
        XCTAssertEqual(opening.status, "Syncing with WebDAV...")
        XCTAssertFalse(opening.canCancel)

        let decrypting = Page.OpeningProgress(step: .decrypting, syncProgress: nil, status: "", canCancel: true)
        guard case .opening(let later)? = make(.unlocking, reference: webDAV, opening: decrypting) else {
            return XCTFail("An open in progress shows the opening page")
        }
        XCTAssertEqual(later.steps.map(\.state), [.done, .current, .upcoming])
        XCTAssertTrue(later.canCancel)
    }

    // MARK: - Helpers

    private func make(
        _ state: DatabaseViewModel.State,
        reference: DatabaseReference,
        hasSavedFile: Bool = true,
        canRelink: Bool = false,
        lastLockCause: DatabaseViewModel.LockCause? = nil,
        opening: Page.OpeningProgress = Page.OpeningProgress(step: .decrypting, syncProgress: nil, status: "",
            canCancel: false)
    ) -> Page? {
        Page.make(state: state, reference: reference, hasSavedFile: hasSavedFile, canRelink: canRelink,
            lastLockCause: lastLockCause, opening: opening)
    }

    private func recoveryActions(
        _ failure: DatabaseOpenFailure,
        reference: DatabaseReference,
        canRelink: Bool = false
    ) -> [Page.RecoveryAction] {
        guard case .recovery(let recovery)? = make(.error(failure), reference: reference, canRelink: canRelink) else {
            XCTFail("\(failure.errorCode) should show a recovery page")
            return []
        }
        return recovery.actions
    }

    private func failure(_ code: String, _ category: DatabaseOpenFailure.Category) -> DatabaseOpenFailure {
        DatabaseOpenFailure(title: "Title \(code)", summary: "Summary \(code)", technicalDetails: "", errorCode: code,
            category: category, countsTowardFailedAttempts: false, canChooseDifferentFile: false)
    }
}
#endif
