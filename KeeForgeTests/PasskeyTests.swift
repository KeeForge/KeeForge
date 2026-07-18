import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

final class PasskeyCredentialTests: XCTestCase {

    // MARK: - PasskeyCredential parsing

    func testParsesValidPasskeyFields() {
        let fields = makePasskeyFields()
        let passkey = PasskeyCredential(customFields: fields)
        XCTAssertNotNil(passkey)
        XCTAssertEqual(passkey?.relyingParty, "example.com")
        XCTAssertEqual(passkey?.username, "alice@example.com")
        XCTAssertEqual(passkey?.credentialID, "dGVzdC1jcmVkZW50aWFsLWlk")
        XCTAssertEqual(passkey?.userHandle, "dXNlci1oYW5kbGU")
    }

    func testReturnsNilWhenCredentialIDMissing() {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.credentialIDKey)
        XCTAssertNil(PasskeyCredential(customFields: fields))
    }

    func testReturnsNilWhenPrivateKeyMissing() {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.privateKeyPEMKey)
        XCTAssertNil(PasskeyCredential(customFields: fields))
    }

    func testReturnsNilWhenRelyingPartyMissing() {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.relyingPartyKey)
        XCTAssertNil(PasskeyCredential(customFields: fields))
    }

    func testReturnsNilWhenUsernameMissing() {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.usernameKey)
        XCTAssertNil(PasskeyCredential(customFields: fields))
    }

    func testReturnsNilWhenUserHandleMissing() {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.userHandleKey)
        XCTAssertNil(PasskeyCredential(customFields: fields))
    }

    func testReturnsNilWhenFieldEmpty() {
        var fields = makePasskeyFields()
        fields[PasskeyCredential.relyingPartyKey] = ""
        XCTAssertNil(PasskeyCredential(customFields: fields))
    }

    func testReturnsNilForEmptyCustomFields() {
        XCTAssertNil(PasskeyCredential(customFields: [:]))
    }

    // MARK: - Legacy field name compatibility

    func testParsesLegacyCredentialIDAndUsernameKeys() {
        // Passkeys written by Strongbox / older KeePassXC use legacy field names
        // for the credential ID and username.
        let fields: [String: String] = [
            PasskeyCredential.legacyCredentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.privateKeyPEMKey: "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZz8y\n-----END PRIVATE KEY-----",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.legacyUsernameKey: "alice@example.com",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
        ]
        let passkey = PasskeyCredential(customFields: fields)
        XCTAssertNotNil(passkey)
        XCTAssertEqual(passkey?.credentialID, "dGVzdC1jcmVkZW50aWFsLWlk")
        XCTAssertEqual(passkey?.username, "alice@example.com")
        XCTAssertEqual(passkey?.relyingParty, "example.com")
    }

    func testCurrentKeysTakePrecedenceOverLegacyKeys() {
        var fields = makePasskeyFields()
        fields[PasskeyCredential.legacyCredentialIDKey] = "bGVnYWN5LWlk"
        fields[PasskeyCredential.legacyUsernameKey] = "legacy@example.com"
        let passkey = PasskeyCredential(customFields: fields)
        XCTAssertEqual(passkey?.credentialID, "dGVzdC1jcmVkZW50aWFsLWlk")
        XCTAssertEqual(passkey?.username, "alice@example.com")
    }

    func testFallsBackToLegacyKeyWhenCurrentKeyEmpty() {
        var fields = makePasskeyFields()
        fields[PasskeyCredential.credentialIDKey] = ""
        fields[PasskeyCredential.legacyCredentialIDKey] = "dGVzdC1jcmVkZW50aWFsLWlk"
        let passkey = PasskeyCredential(customFields: fields)
        XCTAssertEqual(passkey?.credentialID, "dGVzdC1jcmVkZW50aWFsLWlk")
    }

    func testAllFieldKeysIncludesLegacyKeys() {
        XCTAssertTrue(PasskeyCredential.allFieldKeys.contains(PasskeyCredential.legacyCredentialIDKey))
        XCTAssertTrue(PasskeyCredential.allFieldKeys.contains(PasskeyCredential.legacyUsernameKey))
    }

    func testDisplayCustomFieldsExcludesLegacyPasskeyKeys() {
        let fields: [String: String] = [
            PasskeyCredential.legacyCredentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.privateKeyPEMKey: "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZz8y\n-----END PRIVATE KEY-----",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.legacyUsernameKey: "alice@example.com",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
            "CustomNote": "hello",
        ]
        let entry = makeEntry(customFields: fields)
        let displayFields = entry.displayCustomFields
        XCTAssertEqual(displayFields.count, 1)
        XCTAssertEqual(displayFields["CustomNote"], "hello")
        XCTAssertNil(displayFields[PasskeyCredential.legacyCredentialIDKey])
        XCTAssertNil(displayFields[PasskeyCredential.legacyUsernameKey])
    }

    // MARK: - Base64URL decoding

    func testCredentialIDDataDecodes() {
        let passkey = PasskeyCredential(customFields: makePasskeyFields())!
        let data = passkey.credentialIDData
        XCTAssertNotNil(data)
        XCTAssertEqual(String(data: data!, encoding: .utf8), "test-credential-id")
    }

    func testUserHandleDataDecodes() {
        let passkey = PasskeyCredential(customFields: makePasskeyFields())!
        let data = passkey.userHandleData
        XCTAssertNotNil(data)
        XCTAssertEqual(String(data: data!, encoding: .utf8), "user-handle")
    }

    // MARK: - KPEntry integration

    func testEntryHasPasskeyWhenFieldsPresent() {
        let entry = makeEntry(customFields: makePasskeyFields())
        XCTAssertTrue(entry.hasPasskey)
        XCTAssertNotNil(entry.passkeyCredential)
    }

    func testEntryHasNoPasskeyWhenFieldsMissing() {
        let entry = makeEntry(customFields: [:])
        XCTAssertFalse(entry.hasPasskey)
        XCTAssertNil(entry.passkeyCredential)
    }

    func testDisplayCustomFieldsExcludesPasskeyFields() {
        var fields = makePasskeyFields()
        fields["CustomNote"] = "hello"
        let entry = makeEntry(customFields: fields)
        let displayFields = entry.displayCustomFields
        XCTAssertEqual(displayFields.count, 1)
        XCTAssertEqual(displayFields["CustomNote"], "hello")
        for key in PasskeyCredential.allFieldKeys {
            XCTAssertNil(displayFields[key])
        }
    }

    func testDisplayCustomFieldsEmptyWhenOnlyPasskeyFields() {
        let entry = makeEntry(customFields: makePasskeyFields())
        XCTAssertTrue(entry.displayCustomFields.isEmpty)
    }

    // MARK: - Base64URL encode/decode roundtrip

    func testBase64URLRoundtrip() {
        let original = Data([0x00, 0xFF, 0xFE, 0x01, 0x02, 0x03])
        let encoded = base64URLEncode(original)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        let decoded = base64URLDecode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testBase64URLDecodesWithPadding() {
        // "dGVzdA==" is standard base64 for "test"
        // Base64URL version without padding: "dGVzdA"
        let decoded = base64URLDecode("dGVzdA")
        XCTAssertEqual(String(data: decoded!, encoding: .utf8), "test")
    }

    // MARK: - CredentialIdentityStoreManager passkey identity

    func testPasskeyIdentityCreatedForPasskeyEntry() {
        let entry = makeEntry(customFields: makePasskeyFields())
        let identity = CredentialIdentityStoreManager.passkeyIdentity(for: entry)
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.relyingPartyIdentifier, "example.com")
        XCTAssertEqual(identity?.userName, "alice@example.com")
        XCTAssertEqual(identity?.recordIdentifier, entry.id.uuidString)
    }

    func testPasskeyIdentityNilForNonPasskeyEntry() {
        let entry = makeEntry(customFields: [:])
        XCTAssertNil(CredentialIdentityStoreManager.passkeyIdentity(for: entry))
    }

    // MARK: - Helpers

    private func makePasskeyFields() -> [String: String] {
        [
            PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.privateKeyPEMKey: "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZz8y\n-----END PRIVATE KEY-----",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.usernameKey: "alice@example.com",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
        ]
    }

    private func makeEntry(customFields: [String: String]) -> KPEntry {
        KPEntry(
            title: "Test Entry",
            username: "alice",
            password: .empty,
            url: "https://example.com",
            customFields: customFields
        )
    }
}

// MARK: - PasskeyCrypto Tests

final class PasskeyCryptoTests: XCTestCase {

    func testPEMParsingAndSigning() throws {
        // Generate a test P-256 key and export as PEM
        let key = P256.Signing.PrivateKey()
        let pem = pemEncode(key)

        let privateKey = try PasskeyCrypto.privateKey(fromPEM: pem)

        // Sign an assertion
        let clientDataHash = Data(SHA256.hash(data: Data("test-client-data".utf8)))
        let (authData, signature) = try PasskeyCrypto.signAssertion(
            relyingPartyID: "example.com",
            clientDataHash: clientDataHash,
            privateKey: privateKey
        )

        // Authenticator data should be 37 bytes (32 rpIdHash + 1 flags + 4 counter)
        XCTAssertEqual(authData.count, 37)

        // Verify flags byte: UP | UV | BE | BS
        XCTAssertEqual(authData[32], PasskeyCrypto.assertionFlags)

        // Counter should be 0 (4 bytes big-endian)
        XCTAssertEqual(authData[33], 0)
        XCTAssertEqual(authData[34], 0)
        XCTAssertEqual(authData[35], 0)
        XCTAssertEqual(authData[36], 0)

        // Verify the RP ID hash
        let expectedRPHash = Data(SHA256.hash(data: Data("example.com".utf8)))
        XCTAssertEqual(authData.prefix(32), expectedRPHash)

        // Verify signature is valid
        let publicKey = privateKey.publicKey
        var signedData = authData
        signedData.append(clientDataHash)
        let isValid = try publicKey.isValidSignature(
            P256.Signing.ECDSASignature(derRepresentation: signature),
            for: signedData
        )
        XCTAssertTrue(isValid)
    }

    func testAuthenticatorDataWithCustomCounter() {
        let authData = PasskeyCrypto.buildAuthenticatorData(
            relyingPartyID: "test.example.com",
            counter: 42
        )
        XCTAssertEqual(authData.count, 37)
        XCTAssertEqual(authData[32], PasskeyCrypto.assertionFlags)
        // Counter 42 = 0x0000002A big-endian
        XCTAssertEqual(authData[33], 0)
        XCTAssertEqual(authData[34], 0)
        XCTAssertEqual(authData[35], 0)
        XCTAssertEqual(authData[36], 42)
    }

    func testAuthenticatorDataUsesRegistrationFlagsWhenRequested() {
        let authData = PasskeyCrypto.buildAuthenticatorData(
            relyingPartyID: "example.com",
            flags: PasskeyCrypto.registrationFlags
        )

        XCTAssertEqual(authData.count, 37)
        XCTAssertEqual(authData[32], PasskeyCrypto.registrationFlags)
    }

    func testInvalidPEMThrows() {
        XCTAssertThrowsError(try PasskeyCrypto.privateKey(fromPEM: "not-a-pem")) { error in
            XCTAssertTrue(error is PasskeyError)
        }
    }

    func testPKCS8PEMFormat() throws {
        // Generate key, export as PKCS#8 DER, wrap in PEM
        let key = P256.Signing.PrivateKey()
        let derData = key.derRepresentation
        let base64 = derData.base64EncodedString(options: .lineLength64Characters)
        let pem = "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----"

        let privateKey = try PasskeyCrypto.privateKey(fromPEM: pem)
        XCTAssertEqual(privateKey.publicKey.x963Representation, key.publicKey.x963Representation)
    }

    func testPasskeyIdentityUsesRawLowercasedRelyingPartyIdentifier() {
        let entry = KPEntry(
            title: "Passkey Entry",
            username: "",
            password: .empty,
            url: "https://example.com",
            customFields: [
                PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
                PasskeyCredential.privateKeyPEMKey: "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZz8y\n-----END PRIVATE KEY-----",
                PasskeyCredential.relyingPartyKey: "https://www.Example.com/login",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
            ]
        )
        let identity = CredentialIdentityStoreManager.passkeyIdentity(for: entry)

        // passkeyIdentity uses raw RP identifier (trim + lowercase only, no URL normalization)
        XCTAssertEqual(identity?.relyingPartyIdentifier, "https://www.example.com/login")
    }

    // MARK: - Helpers

    /// Encode a P256 private key as PKCS#8 PEM.
    private func pemEncode(_ key: P256.Signing.PrivateKey) -> String {
        let derData = key.derRepresentation
        let base64 = derData.base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----"
    }
}
