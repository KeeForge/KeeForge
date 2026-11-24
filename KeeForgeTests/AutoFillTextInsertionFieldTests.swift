import CryptoKit
import XCTest
@testable import KeeForge

final class AutoFillTextInsertionFieldTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)
    private let secret = "JBSWY3DPEHPK3PXP"

    private func entry(
        title: String = "Login",
        username: String = "",
        password: String = "",
        totpSecret: String? = nil
    ) throws -> KPEntry {
        var entry = KPEntry(title: title, username: username, password: try .encrypt(password, using: key))
        entry.totpConfig = try totpSecret.map { TOTPConfig(secret: try .encrypt($0, using: key)) }
        return entry
    }

    func testOffersOnlyThePresentFieldsInDisplayOrder() throws {
        XCTAssertEqual(
            AutoFillTextInsertionField.availableFields(for: try entry(username: "u", password: "p", totpSecret: secret)),
            [.username, .password, .verificationCode]
        )
        XCTAssertEqual(AutoFillTextInsertionField.availableFields(for: try entry(password: "p")), [.password])
        XCTAssertEqual(AutoFillTextInsertionField.availableFields(for: try entry(totpSecret: secret)), [.verificationCode])
        XCTAssertEqual(AutoFillTextInsertionField.availableFields(for: try entry(username: "u")), [.username])
        XCTAssertTrue(AutoFillTextInsertionField.availableFields(for: try entry()).isEmpty)
    }

    func testTitleIsNeverUsedAsAUsername() throws {
        let titled = try entry(title: "Bank", password: "p")
        XCTAssertFalse(AutoFillTextInsertionField.username.isAvailable(for: titled))
        XCTAssertNil(AutoFillTextInsertionField.username.text(for: titled, allEntries: [titled], sessionKey: key))
    }

    func testReturnsTheDecryptedUsernameAndPassword() throws {
        let login = try entry(username: "alice", password: "s3cret")
        XCTAssertEqual(AutoFillTextInsertionField.username.text(for: login, allEntries: [login], sessionKey: key), "alice")
        XCTAssertEqual(AutoFillTextInsertionField.password.text(for: login, allEntries: [login], sessionKey: key), "s3cret")
    }

    func testGeneratesTheCodeForTheSelectionTimeAndNeverTheSecret() throws {
        let login = try entry(totpSecret: secret)
        let config = try XCTUnwrap(login.totpConfig)
        let first = Date(timeIntervalSince1970: 1_000_000_000)
        let later = first.addingTimeInterval(60)

        let code = AutoFillTextInsertionField.verificationCode.text(for: login, allEntries: [login], sessionKey: key, date: first)
        let laterCode = AutoFillTextInsertionField.verificationCode.text(for: login, allEntries: [login], sessionKey: key, date: later)

        XCTAssertEqual(code, TOTPGenerator.generateCode(config: config, sessionKey: key, date: first))
        XCTAssertEqual(laterCode, TOTPGenerator.generateCode(config: config, sessionKey: key, date: later))
        XCTAssertNotEqual(code, laterCode)
        XCTAssertNotEqual(code, secret)
        XCTAssertEqual(code?.count, 6)
    }

    func testUndecodableCodeSecretInsertsNothing() throws {
        let broken = try entry(totpSecret: "not base32 !!!")
        XCTAssertNil(AutoFillTextInsertionField.verificationCode.text(for: broken, allEntries: [broken], sessionKey: key))
    }

    func testUndecryptablePasswordInsertsNothing() throws {
        let corrupt = KPEntry(title: "Corrupt", password: EncryptedValue(sealedData: Data([1]), hasValue: true))
        XCTAssertTrue(AutoFillTextInsertionField.password.isAvailable(for: corrupt))
        XCTAssertNil(AutoFillTextInsertionField.password.text(for: corrupt, allEntries: [corrupt], sessionKey: key))
    }

    func testMissingFieldInsertsNothing() throws {
        let passwordOnly = try entry(password: "p")
        XCTAssertNil(AutoFillTextInsertionField.verificationCode.text(for: passwordOnly, allEntries: [passwordOnly], sessionKey: key))
        XCTAssertNil(AutoFillTextInsertionField.username.text(for: passwordOnly, allEntries: [passwordOnly], sessionKey: key))
    }

    func testResolvesFieldReferencesIncludingProtectedTargets() throws {
        let target = try entry(title: "Target", username: "shared-user", password: "shared-pass")
        let referencing = try entry(
            title: "Referencing",
            username: "{REF:U@I:\(target.id.uuidString.replacingOccurrences(of: "-", with: ""))}",
            password: "{REF:P@I:\(target.id.uuidString.replacingOccurrences(of: "-", with: ""))}"
        )
        let all = [target, referencing]
        XCTAssertEqual(AutoFillTextInsertionField.username.text(for: referencing, allEntries: all, sessionKey: key), "shared-user")
        XCTAssertEqual(AutoFillTextInsertionField.password.text(for: referencing, allEntries: all, sessionKey: key), "shared-pass")
    }
}
