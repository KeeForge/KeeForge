import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class TOTPEnrollmentViewModelTests: XCTestCase {
    private let sessionKey = SymmetricKey(size: .bits256)

    private func makeURI(_ string: String = "otpauth://totp/GitHub:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub") throws -> OTPAuthURI {
        try OTPAuthURI(string: string)
    }

    private func makeEntryWithTOTP(title: String) throws -> KPEntry {
        KPEntry(
            title: title,
            totpConfig: TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey))
        )
    }

    // MARK: - Entry candidates

    func testEntryCandidatesExcludeRecycleBinSubtreeAndCarryFolderPaths() throws {
        let recycleBinID = UUID()
        let root = KPGroup(
            name: "Vault",
            entries: [KPEntry(title: "Root Entry")],
            groups: [
                KPGroup(
                    name: "Work",
                    entries: [KPEntry(title: "Work Entry")],
                    groups: [
                        KPGroup(name: "Servers", entries: [KPEntry(title: "Nested Entry")]),
                    ]
                ),
                KPGroup(
                    id: recycleBinID,
                    name: "Recycle Bin",
                    entries: [KPEntry(title: "Trashed Entry")],
                    groups: [
                        KPGroup(name: "Trashed Group", entries: [KPEntry(title: "Deep Trashed Entry")]),
                    ]
                ),
            ]
        )

        let model = TOTPEnrollmentViewModel(
            uri: try makeURI(),
            visibleRoot: root,
            recycleBinGroupID: recycleBinID
        )

        XCTAssertEqual(
            model.filteredEntryCandidates.map(\.title),
            ["Root Entry", "Work Entry", "Nested Entry"]
        )
        XCTAssertEqual(
            model.filteredEntryCandidates.map(\.folderPath),
            [nil, "Work", "Work / Servers"]
        )
    }

    func testSearchFiltersByTitleUsernameAndURLCaseInsensitively() throws {
        let root = KPGroup(
            name: "Vault",
            entries: [
                KPEntry(title: "GitHub"),
                KPEntry(title: "Mail", username: "alice@GITHUB.example"),
                KPEntry(title: "Forge", url: "https://github.com/login"),
                KPEntry(title: "Bank", username: "bob", url: "https://bank.example"),
            ]
        )

        let model = TOTPEnrollmentViewModel(
            uri: try makeURI(),
            visibleRoot: root,
            recycleBinGroupID: nil
        )

        model.searchText = "github"
        XCTAssertEqual(model.filteredEntryCandidates.map(\.title), ["GitHub", "Mail", "Forge"])

        model.searchText = "  BOB  "
        XCTAssertEqual(model.filteredEntryCandidates.map(\.title), ["Bank"])

        model.searchText = "   "
        XCTAssertEqual(model.filteredEntryCandidates.count, 4)
    }

    // MARK: - Group options

    func testGroupOptionsFlattenTreeOrderWithDepthsExcludingRecycleBin() throws {
        let recycleBinID = UUID()
        let root = KPGroup(
            name: "Vault",
            groups: [
                KPGroup(
                    name: "Work",
                    groups: [KPGroup(name: "Servers")]
                ),
                KPGroup(
                    id: recycleBinID,
                    name: "Recycle Bin",
                    groups: [KPGroup(name: "Trashed Group")]
                ),
                KPGroup(name: "Personal"),
            ]
        )

        let model = TOTPEnrollmentViewModel(
            uri: try makeURI(),
            visibleRoot: root,
            recycleBinGroupID: recycleBinID
        )

        XCTAssertEqual(
            model.groupOptions.map(\.name),
            ["Vault", "Work", "Servers", "Personal"]
        )
        XCTAssertEqual(model.groupOptions.map(\.depth), [0, 1, 2, 1])
    }

    // MARK: - Prefill derivation

    func testPrefillUsesIssuerAndAccountName() throws {
        let model = TOTPEnrollmentViewModel(
            uri: try makeURI("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"),
            visibleRoot: nil,
            recycleBinGroupID: nil
        )

        XCTAssertEqual(model.prefilledTitle, "GitHub")
        XCTAssertEqual(model.prefilledUsername, "alice")
        XCTAssertEqual(model.summaryTitle, "GitHub")
        XCTAssertEqual(model.summarySubtitle, "alice")
    }

    func testPrefillFallsBackToAccountNameWithoutIssuer() throws {
        let model = TOTPEnrollmentViewModel(
            uri: try makeURI("otpauth://totp/alice@example.com?secret=JBSWY3DPEHPK3PXP"),
            visibleRoot: nil,
            recycleBinGroupID: nil
        )

        XCTAssertEqual(model.prefilledTitle, "alice@example.com")
        XCTAssertEqual(model.prefilledUsername, "alice@example.com")
        XCTAssertEqual(model.summaryTitle, "alice@example.com")
        XCTAssertNil(model.summarySubtitle)
    }

    func testPrefillIsEmptyWithoutIssuerOrAccountName() throws {
        let model = TOTPEnrollmentViewModel(
            uri: try makeURI("otpauth://totp/?secret=JBSWY3DPEHPK3PXP"),
            visibleRoot: nil,
            recycleBinGroupID: nil
        )

        XCTAssertEqual(model.prefilledTitle, "")
        XCTAssertEqual(model.prefilledUsername, "")
        // The localized fallback; asserted non-empty rather than against one
        // locale's wording.
        XCTAssertFalse(model.summaryTitle.isEmpty)
        XCTAssertNil(model.summarySubtitle)
    }

    // MARK: - Replace confirmation

    func testReplaceConfirmationRequiredOnlyWhenTargetHasTOTP() throws {
        let root = KPGroup(
            name: "Vault",
            entries: [
                KPEntry(title: "Plain"),
                try makeEntryWithTOTP(title: "Enrolled"),
            ]
        )

        let model = TOTPEnrollmentViewModel(
            uri: try makeURI(),
            visibleRoot: root,
            recycleBinGroupID: nil
        )

        let candidates = model.filteredEntryCandidates
        XCTAssertEqual(candidates.count, 2)
        XCTAssertFalse(model.requiresReplaceConfirmation(candidates[0]))
        XCTAssertTrue(model.requiresReplaceConfirmation(candidates[1]))
    }

    // MARK: - URL routing helper

    func testIsOTPAuthURLRecognizesSchemeCaseInsensitively() throws {
        XCTAssertTrue(OTPAuthURI.isOTPAuthURL(try XCTUnwrap(URL(string: "otpauth://totp/a?secret=JBSWY3DP"))))
        XCTAssertTrue(OTPAuthURI.isOTPAuthURL(try XCTUnwrap(URL(string: "OTPAUTH://totp/a?secret=JBSWY3DP"))))
        XCTAssertFalse(OTPAuthURI.isOTPAuthURL(try XCTUnwrap(URL(string: "db-abc123://oauth/callback"))))
        XCTAssertFalse(OTPAuthURI.isOTPAuthURL(try XCTUnwrap(URL(string: "msauth.com.example.app://auth"))))
        XCTAssertFalse(OTPAuthURI.isOTPAuthURL(URL(fileURLWithPath: "/tmp/vault.kdbx")))
    }
}
