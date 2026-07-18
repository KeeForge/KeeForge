import CryptoKit
import XCTest
@testable import KeeForge

/// Verifies PasskeyCredential parsing from known KPEX_PASSKEY_* field values,
/// validating the data that would appear in EntryDetailView's Passkey section.
final class PasskeyDisplayTests: XCTestCase {

    private let sessionKey = SymmetricKey(size: .bits256)

    private func sealedTestKey() throws -> EncryptedValue {
        try EncryptedValue.encrypt(
            "-----BEGIN PRIVATE KEY-----\nMIGH...\n-----END PRIVATE KEY-----",
            using: sessionKey
        )
    }

    func testPasskeySectionFieldsMatchExpectedValues() throws {
        let fields: [String: String] = [
            "KPEX_PASSKEY_CREDENTIAL_ID": "YWJjZGVmZw",
            "KPEX_PASSKEY_RELYING_PARTY": "login.example.com",
            "KPEX_PASSKEY_USERNAME": "bob@example.com",
            "KPEX_PASSKEY_USER_HANDLE": "Ym9iLWhhbmRsZQ",
        ]

        let entry = KPEntry(
            title: "Example Passkey",
            username: "bob",
            customFields: fields,
            passkeyPrivateKey: try sealedTestKey()
        )

        // Entry should report having a passkey
        XCTAssertTrue(entry.hasPasskey)

        // Passkey section fields should match
        let passkey = try XCTUnwrap(entry.passkeyCredential)
        XCTAssertEqual(passkey.relyingParty, "login.example.com")
        XCTAssertEqual(passkey.username, "bob@example.com")
        XCTAssertEqual(passkey.credentialID, "YWJjZGVmZw")

        // Credential ID should decode correctly
        let decodedID = try XCTUnwrap(passkey.credentialIDData)
        XCTAssertEqual(String(data: decodedID, encoding: .utf8), "abcdefg")

        // User handle should decode correctly
        let decodedHandle = try XCTUnwrap(passkey.userHandleData)
        XCTAssertEqual(String(data: decodedHandle, encoding: .utf8), "bob-handle")
    }

    func testEntryWithoutPasskeyFieldsHasNoPasskeySection() {
        let entry = KPEntry(
            title: "Regular Entry",
            username: "alice",
            customFields: ["Notes": "just a note"]
        )

        XCTAssertFalse(entry.hasPasskey)
        XCTAssertNil(entry.passkeyCredential)
    }

    func testEntryWithPartialPasskeyFieldsHasNoPasskeySection() throws {
        // Only relying party and username — missing required fields
        let fields: [String: String] = [
            "KPEX_PASSKEY_RELYING_PARTY": "example.com",
            "KPEX_PASSKEY_USERNAME": "alice@example.com",
        ]

        let entry = KPEntry(
            title: "Partial Passkey",
            customFields: fields,
            passkeyPrivateKey: try sealedTestKey()
        )
        XCTAssertFalse(entry.hasPasskey)
        XCTAssertNil(entry.passkeyCredential)
    }

    func testEntryWithMetadataButNoPrivateKeyHasNoPasskeySection() {
        let fields: [String: String] = [
            "KPEX_PASSKEY_CREDENTIAL_ID": "YWJjZGVmZw",
            "KPEX_PASSKEY_RELYING_PARTY": "example.com",
            "KPEX_PASSKEY_USERNAME": "alice@example.com",
            "KPEX_PASSKEY_USER_HANDLE": "dXNlci1oYW5kbGU",
        ]

        let entry = KPEntry(title: "Keyless Passkey", customFields: fields)
        XCTAssertFalse(entry.hasPasskey)
        XCTAssertNil(entry.passkeyCredential)
    }

    func testPasskeyFieldsExcludedFromDisplayCustomFields() throws {
        var fields: [String: String] = [
            "KPEX_PASSKEY_CREDENTIAL_ID": "YWJjZGVmZw",
            "KPEX_PASSKEY_RELYING_PARTY": "example.com",
            "KPEX_PASSKEY_USERNAME": "alice@example.com",
            "KPEX_PASSKEY_USER_HANDLE": "dXNlci1oYW5kbGU",
        ]
        fields["MyCustomField"] = "visible"

        let entry = KPEntry(
            title: "Mixed Fields",
            customFields: fields,
            passkeyPrivateKey: try sealedTestKey()
        )

        // displayCustomFields should only contain non-passkey fields
        XCTAssertEqual(entry.displayCustomFields.count, 1)
        XCTAssertEqual(entry.displayCustomFields["MyCustomField"], "visible")
    }
}
