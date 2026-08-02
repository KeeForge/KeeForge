import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

final class PasskeyCredentialTests: XCTestCase {

    private let sessionKey = SymmetricKey(size: .bits256)
    /// Owning-database id passed to the identity builder; the produced
    /// identity's record identifier is tagged with it (slice 02).
    private let someDatabaseID = UUID()

    private static let testPEM = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZz8y\n-----END PRIVATE KEY-----"

    // MARK: - PasskeyCredential parsing

    func testParsesValidPasskeyFields() throws {
        let passkey = PasskeyCredential(customFields: makePasskeyFields(), privateKey: try makeSealedKey())
        XCTAssertNotNil(passkey)
        XCTAssertEqual(passkey?.relyingParty, "example.com")
        XCTAssertEqual(passkey?.username, "alice@example.com")
        XCTAssertEqual(passkey?.credentialID, "dGVzdC1jcmVkZW50aWFsLWlk")
        XCTAssertEqual(passkey?.userHandle, "dXNlci1oYW5kbGU")
    }

    func testPrivateKeyPEMDecryptsWithSessionKey() throws {
        let passkey = try XCTUnwrap(
            PasskeyCredential(customFields: makePasskeyFields(), privateKey: try makeSealedKey())
        )
        XCTAssertEqual(try passkey.privateKeyPEM(using: sessionKey), Self.testPEM)
    }

    func testPrivateKeyPEMIsUnreadableWithWrongSessionKey() throws {
        let passkey = try XCTUnwrap(
            PasskeyCredential(customFields: makePasskeyFields(), privateKey: try makeSealedKey())
        )
        XCTAssertThrowsError(try passkey.privateKeyPEM(using: SymmetricKey(size: .bits256)))
    }

    func testReturnsNilWhenCredentialIDMissing() throws {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.credentialIDKey)
        XCTAssertNil(PasskeyCredential(customFields: fields, privateKey: try makeSealedKey()))
    }

    func testReturnsNilWhenPrivateKeyMissing() {
        XCTAssertNil(PasskeyCredential(customFields: makePasskeyFields(), privateKey: nil))
    }

    func testReturnsNilWhenPrivateKeyEmpty() {
        XCTAssertNil(PasskeyCredential(customFields: makePasskeyFields(), privateKey: .empty))
    }

    func testReturnsNilWhenRelyingPartyMissing() throws {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.relyingPartyKey)
        XCTAssertNil(PasskeyCredential(customFields: fields, privateKey: try makeSealedKey()))
    }

    func testReturnsNilWhenUsernameMissing() throws {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.usernameKey)
        XCTAssertNil(PasskeyCredential(customFields: fields, privateKey: try makeSealedKey()))
    }

    func testReturnsNilWhenUserHandleMissing() throws {
        var fields = makePasskeyFields()
        fields.removeValue(forKey: PasskeyCredential.userHandleKey)
        XCTAssertNil(PasskeyCredential(customFields: fields, privateKey: try makeSealedKey()))
    }

    func testReturnsNilWhenFieldEmpty() throws {
        var fields = makePasskeyFields()
        fields[PasskeyCredential.relyingPartyKey] = ""
        XCTAssertNil(PasskeyCredential(customFields: fields, privateKey: try makeSealedKey()))
    }

    func testReturnsNilForEmptyCustomFields() throws {
        XCTAssertNil(PasskeyCredential(customFields: [:], privateKey: try makeSealedKey()))
    }

    // MARK: - Legacy field name compatibility

    func testParsesLegacyCredentialIDAndUsernameKeys() throws {
        // Passkeys written by Strongbox / older KeePassXC use legacy field names
        // for the credential ID and username.
        let fields: [String: String] = [
            PasskeyCredential.legacyCredentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.legacyUsernameKey: "alice@example.com",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
        ]
        let passkey = PasskeyCredential(customFields: fields, privateKey: try makeSealedKey())
        XCTAssertNotNil(passkey)
        XCTAssertEqual(passkey?.credentialID, "dGVzdC1jcmVkZW50aWFsLWlk")
        XCTAssertEqual(passkey?.username, "alice@example.com")
        XCTAssertEqual(passkey?.relyingParty, "example.com")
    }

    func testCurrentKeysTakePrecedenceOverLegacyKeys() throws {
        var fields = makePasskeyFields()
        fields[PasskeyCredential.legacyCredentialIDKey] = "bGVnYWN5LWlk"
        fields[PasskeyCredential.legacyUsernameKey] = "legacy@example.com"
        let passkey = PasskeyCredential(customFields: fields, privateKey: try makeSealedKey())
        XCTAssertEqual(passkey?.credentialID, "dGVzdC1jcmVkZW50aWFsLWlk")
        XCTAssertEqual(passkey?.username, "alice@example.com")
    }

    func testFallsBackToLegacyKeyWhenCurrentKeyEmpty() throws {
        var fields = makePasskeyFields()
        fields[PasskeyCredential.credentialIDKey] = ""
        fields[PasskeyCredential.legacyCredentialIDKey] = "dGVzdC1jcmVkZW50aWFsLWlk"
        let passkey = PasskeyCredential(customFields: fields, privateKey: try makeSealedKey())
        XCTAssertEqual(passkey?.credentialID, "dGVzdC1jcmVkZW50aWFsLWlk")
    }

    func testAllFieldKeysIncludesLegacyKeys() {
        XCTAssertTrue(PasskeyCredential.allFieldKeys.contains(PasskeyCredential.legacyCredentialIDKey))
        XCTAssertTrue(PasskeyCredential.allFieldKeys.contains(PasskeyCredential.legacyUsernameKey))
    }

    func testDisplayCustomFieldsExcludesLegacyPasskeyKeys() throws {
        let fields: [String: String] = [
            PasskeyCredential.legacyCredentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.legacyUsernameKey: "alice@example.com",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
            "CustomNote": "hello",
        ]
        let entry = makeEntry(customFields: fields, passkeyPrivateKey: try makeSealedKey())
        let displayFields = entry.displayCustomFields
        XCTAssertEqual(displayFields.count, 1)
        XCTAssertEqual(displayFields["CustomNote"], "hello")
        XCTAssertNil(displayFields[PasskeyCredential.legacyCredentialIDKey])
        XCTAssertNil(displayFields[PasskeyCredential.legacyUsernameKey])
    }

    // MARK: - Base64URL decoding

    func testCredentialIDDataDecodes() throws {
        let passkey = try XCTUnwrap(
            PasskeyCredential(customFields: makePasskeyFields(), privateKey: try makeSealedKey())
        )
        let data = try XCTUnwrap(passkey.credentialIDData)
        XCTAssertEqual(String(data: data, encoding: .utf8), "test-credential-id")
    }

    func testUserHandleDataDecodes() throws {
        let passkey = try XCTUnwrap(
            PasskeyCredential(customFields: makePasskeyFields(), privateKey: try makeSealedKey())
        )
        let data = try XCTUnwrap(passkey.userHandleData)
        XCTAssertEqual(String(data: data, encoding: .utf8), "user-handle")
    }

    // MARK: - KPEntry integration

    func testEntryHasPasskeyWhenFieldsPresent() throws {
        let entry = makeEntry(customFields: makePasskeyFields(), passkeyPrivateKey: try makeSealedKey())
        XCTAssertTrue(entry.hasPasskey)
        XCTAssertNotNil(entry.passkeyCredential)
    }

    func testEntryHasNoPasskeyWhenFieldsMissing() {
        let entry = makeEntry(customFields: [:])
        XCTAssertFalse(entry.hasPasskey)
        XCTAssertNil(entry.passkeyCredential)
    }

    func testEntryHasNoPasskeyWithoutDivertedPrivateKey() {
        // Metadata alone is not a usable passkey; the private key rides on
        // KPEntry.passkeyPrivateKey after the parser diverts it.
        let entry = makeEntry(customFields: makePasskeyFields())
        XCTAssertFalse(entry.hasPasskey)
        XCTAssertNil(entry.passkeyCredential)
    }

    func testDisplayCustomFieldsExcludesPasskeyFields() throws {
        var fields = makePasskeyFields()
        fields["CustomNote"] = "hello"
        let entry = makeEntry(customFields: fields, passkeyPrivateKey: try makeSealedKey())
        let displayFields = entry.displayCustomFields
        XCTAssertEqual(displayFields.count, 1)
        XCTAssertEqual(displayFields["CustomNote"], "hello")
        for key in PasskeyCredential.allFieldKeys {
            XCTAssertNil(displayFields[key])
        }
    }

    func testDisplayCustomFieldsEmptyWhenOnlyPasskeyFields() throws {
        let entry = makeEntry(customFields: makePasskeyFields(), passkeyPrivateKey: try makeSealedKey())
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

    func testPasskeyIdentityCreatedForPasskeyEntry() throws {
        let entry = makeEntry(customFields: makePasskeyFields(), passkeyPrivateKey: try makeSealedKey())
        let identity = CredentialIdentityStoreManager.passkeyIdentity(for: entry, in: someDatabaseID)
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.relyingPartyIdentifier, "example.com")
        XCTAssertEqual(identity?.userName, "alice@example.com")
        XCTAssertEqual(
            identity?.recordIdentifier,
            CredentialRecordIdentifier(databaseID: someDatabaseID, entryID: entry.id).encoded
        )
    }

    func testPasskeyIdentityNilForNonPasskeyEntry() {
        let entry = makeEntry(customFields: [:])
        XCTAssertNil(CredentialIdentityStoreManager.passkeyIdentity(for: entry, in: someDatabaseID))
    }

    // MARK: - Helpers

    private func makePasskeyFields() -> [String: String] {
        [
            PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.usernameKey: "alice@example.com",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
        ]
    }

    private func makeSealedKey() throws -> EncryptedValue {
        try EncryptedValue.encrypt(Self.testPEM, using: sessionKey)
    }

    private func makeEntry(
        customFields: [String: String],
        passkeyPrivateKey: EncryptedValue? = nil
    ) -> KPEntry {
        KPEntry(
            title: "Test Entry",
            username: "alice",
            password: .empty,
            url: "https://example.com",
            customFields: customFields,
            passkeyPrivateKey: passkeyPrivateKey
        )
    }
}

// MARK: - PasskeyCrypto Tests

final class PasskeyCryptoTests: XCTestCase {

    private let sessionKey = SymmetricKey(size: .bits256)

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

    func testSigningWithSessionSealedPrivateKey() throws {
        // The full just-in-time path: seal the PEM under the session key as
        // the parser does, decrypt through PasskeyCredential, and sign.
        let key = P256.Signing.PrivateKey()
        let credential = try XCTUnwrap(
            PasskeyCredential(
                customFields: [
                    PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
                    PasskeyCredential.relyingPartyKey: "example.com",
                    PasskeyCredential.usernameKey: "alice@example.com",
                    PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
                ],
                privateKey: try EncryptedValue.encrypt(pemEncode(key), using: sessionKey)
            )
        )

        let privateKey = try PasskeyCrypto.privateKey(
            fromPEM: credential.privateKeyPEM(using: sessionKey)
        )
        XCTAssertEqual(privateKey.publicKey.x963Representation, key.publicKey.x963Representation)

        let clientDataHash = Data(SHA256.hash(data: Data("test-client-data".utf8)))
        let (authData, signature) = try PasskeyCrypto.signAssertion(
            relyingPartyID: "example.com",
            clientDataHash: clientDataHash,
            privateKey: privateKey
        )
        var signedData = authData
        signedData.append(clientDataHash)
        XCTAssertTrue(
            try key.publicKey.isValidSignature(
                P256.Signing.ECDSASignature(derRepresentation: signature),
                for: signedData
            )
        )
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

    func testRawPrivateScalarParses() throws {
        let pem = """
        -----BEGIN PRIVATE KEY-----
        PumgYNRCqsQQNNjL16jznBA4EhFbth/8NX9evFmFl2s=
        -----END PRIVATE KEY-----
        """

        let privateKey = try PasskeyCrypto.privateKey(fromPEM: pem)

        XCTAssertEqual(
            privateKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
            Self.sec1RawScalarHex
        )
    }

    func testInvalid32BytePrivateScalarThrowsInvalidKeyData() {
        let pem = Data(repeating: 0, count: 32).base64EncodedString()

        XCTAssertThrowsError(try PasskeyCrypto.privateKey(fromPEM: pem)) { error in
            guard case PasskeyError.invalidKeyData = error else {
                return XCTFail("Expected invalidKeyData, got \(error)")
            }
        }
    }

    func testInvalid33BytePrivateKeyThrowsInvalidKeyData() {
        let pem = Data(repeating: 0, count: 33).base64EncodedString()

        XCTAssertThrowsError(try PasskeyCrypto.privateKey(fromPEM: pem)) { error in
            guard case PasskeyError.invalidKeyData = error else {
                return XCTFail("Expected invalidKeyData, got \(error)")
            }
        }
    }

    // MARK: - SEC1 PEM ("BEGIN EC PRIVATE KEY")

    // `PasskeyCrypto.privateKey(fromPEM:)` documents support for the SEC1
    // container as well as PKCS#8, but every other test here feeds it
    // CryptoKit's own `derRepresentation`, which is PKCS#8. These fixed
    // vectors are the SEC1 form third-party tooling emits.
    //
    // Generated offline, once, with:
    //   openssl ecparam -name prime256v1 -genkey -noout -out sec1.pem
    //   openssl pkcs8 -topk8 -nocrypt -in sec1.pem
    // Both PEMs below therefore hold the same P-256 private scalar.
    private static let sec1PEM = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEID7poGDUQqrEEDTYy9eo85wQOBIRW7Yf/DV/XrxZhZdroAoGCCqGSM49
    AwEHoUQDQgAE5+ZYoZaRmONJjcy3jwOSACL3Mue6vVdWV64WSrAjJ48cUbg1WUsv
    uZTc5OGXPyaiqNj/+as0tDJZF+9LnTpHBw==
    -----END EC PRIVATE KEY-----
    """

    private static let equivalentPKCS8PEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgPumgYNRCqsQQNNjL
    16jznBA4EhFbth/8NX9evFmFl2uhRANCAATn5lihlpGY40mNzLePA5IAIvcy57q9
    V1ZXrhZKsCMnjxxRuDVZSy+5lNzk4Zc/JqKo2P/5qzS0MlkX70udOkcH
    -----END PRIVATE KEY-----
    """

    /// Raw 32-byte private scalar shared by both PEMs above.
    private static let sec1RawScalarHex =
        "3ee9a060d442aac41034d8cbd7a8f39c103812115bb61ffc357f5ebc5985976b"

    func testSEC1PEMYieldsTheSameKeyAsItsPKCS8Encoding() throws {
        let fromSEC1 = try PasskeyCrypto.privateKey(fromPEM: Self.sec1PEM)
        let fromPKCS8 = try PasskeyCrypto.privateKey(fromPEM: Self.equivalentPKCS8PEM)

        XCTAssertEqual(fromSEC1.rawRepresentation.map { String(format: "%02x", $0) }.joined(), Self.sec1RawScalarHex)
        XCTAssertEqual(fromSEC1.rawRepresentation, fromPKCS8.rawRepresentation)
        XCTAssertEqual(fromSEC1.publicKey.x963Representation, fromPKCS8.publicKey.x963Representation)
    }

    func testSEC1PEMSignsAssertionsVerifiableWithThePKCS8DerivedPublicKey() throws {
        let fromSEC1 = try PasskeyCrypto.privateKey(fromPEM: Self.sec1PEM)
        let fromPKCS8 = try PasskeyCrypto.privateKey(fromPEM: Self.equivalentPKCS8PEM)

        let clientDataHash = Data(SHA256.hash(data: Data("sec1-client-data".utf8)))
        let (authData, signature) = try PasskeyCrypto.signAssertion(
            relyingPartyID: "example.com",
            clientDataHash: clientDataHash,
            privateKey: fromSEC1
        )
        var signedData = authData
        signedData.append(clientDataHash)

        XCTAssertTrue(
            try fromPKCS8.publicKey.isValidSignature(
                P256.Signing.ECDSASignature(derRepresentation: signature),
                for: signedData
            ),
            "A signature made with the SEC1-parsed key must verify against the PKCS#8-parsed public key"
        )
    }

    func testSEC1PEMWithCRLFAndSurroundingWhitespaceStillParses() throws {
        // Key files copied out of desktop tooling routinely arrive CRLF-ended.
        let crlfPEM = "  " + Self.sec1PEM.replacingOccurrences(of: "\n", with: "\r\n") + "  "

        let key = try PasskeyCrypto.privateKey(fromPEM: crlfPEM)

        XCTAssertEqual(key.rawRepresentation.map { String(format: "%02x", $0) }.joined(), Self.sec1RawScalarHex)
    }

    func testPasskeyIdentityUsesRawLowercasedRelyingPartyIdentifier() throws {
        let entry = KPEntry(
            title: "Passkey Entry",
            username: "",
            password: .empty,
            url: "https://example.com",
            customFields: [
                PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
                PasskeyCredential.relyingPartyKey: "https://www.Example.com/login",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
            ],
            passkeyPrivateKey: try EncryptedValue.encrypt(
                pemEncode(P256.Signing.PrivateKey()),
                using: sessionKey
            )
        )
        let identity = CredentialIdentityStoreManager.passkeyIdentity(for: entry, in: UUID())

        // passkeyIdentity uses raw RP identifier (trim + lowercase only, no URL normalization)
        XCTAssertEqual(identity?.relyingPartyIdentifier, "https://www.example.com/login")
    }

    // MARK: - Registration authenticator data

    /// Fixed key + fixed credential ID so every byte offset below is pinned.
    private func fixedRegistrationFixture() throws -> (key: P256.Signing.PrivateKey, credentialID: Data) {
        let key = try PasskeyCrypto.privateKey(fromPEM: Self.equivalentPKCS8PEM)
        return (key, Data(repeating: 0xAB, count: 32))
    }

    func testAAGUIDMatchesProductIdentifier() {
        XCTAssertEqual(PasskeyCrypto.aaguid.count, 16)
        XCTAssertEqual(
            PasskeyCrypto.aaguid.map { String(format: "%02x", $0) }.joined(),
            "ff55d8c0f4fb40169fdd56dbbd251802"
        )
    }

    func testGeneratedCredentialIDIs32RandomBytes() throws {
        let first = try PasskeyCrypto.generateCredentialID()
        let second = try PasskeyCrypto.generateCredentialID()
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(second.count, 32)
        XCTAssertNotEqual(first, second)
    }

    func testRegistrationAuthenticatorDataLayout() throws {
        let (key, credentialID) = try fixedRegistrationFixture()
        let authData = PasskeyCrypto.buildRegistrationAuthenticatorData(
            relyingPartyID: "example.com",
            credentialID: credentialID,
            publicKey: key.publicKey
        )

        // 37 (assertion prefix) + 16 (AAGUID) + 2 (len) + 32 (credID) + 77 (COSE key)
        XCTAssertEqual(authData.count, 164)

        let expectedRPHash = Data(SHA256.hash(data: Data("example.com".utf8)))
        XCTAssertEqual(authData.prefix(32), expectedRPHash)

        // Flags: UP | UV | AT | BE | BS
        XCTAssertEqual(authData[32], PasskeyCrypto.registrationFlags)
        XCTAssertEqual(authData[32], 0x5D)

        // Sign count is always zero
        XCTAssertEqual(authData.subdata(in: 33..<37), Data(repeating: 0, count: 4))

        XCTAssertEqual(authData.subdata(in: 37..<53), PasskeyCrypto.aaguid)

        // Credential ID length, big-endian
        XCTAssertEqual(authData[53], 0x00)
        XCTAssertEqual(authData[54], 0x20)
        XCTAssertEqual(authData.subdata(in: 55..<87), credentialID)

        // Followed by the COSE key map
        XCTAssertEqual(authData[87], 0xA5)
    }

    func testCOSEKeyEncodesUncompressedCoordinates() throws {
        let (key, credentialID) = try fixedRegistrationFixture()
        let authData = PasskeyCrypto.buildRegistrationAuthenticatorData(
            relyingPartyID: "example.com",
            credentialID: credentialID,
            publicKey: key.publicKey
        )
        let coseKey = authData.subdata(in: 87..<authData.count)

        // {1: 2, 3: -7, -1: 1, -2: x, -3: y} in canonical order
        XCTAssertEqual(coseKey.prefix(7), Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01]))
        XCTAssertEqual(coseKey.subdata(in: 7..<10), Data([0x21, 0x58, 0x20]))
        let x = coseKey.subdata(in: 10..<42)
        XCTAssertEqual(coseKey.subdata(in: 42..<45), Data([0x22, 0x58, 0x20]))
        let y = coseKey.subdata(in: 45..<77)
        XCTAssertEqual(coseKey.count, 77)

        // x963Representation is 0x04 || x || y; each coordinate exactly 32 bytes
        let x963 = key.publicKey.x963Representation
        XCTAssertEqual(x.count, 32)
        XCTAssertEqual(y.count, 32)
        XCTAssertEqual(x, Data(x963.dropFirst(1).prefix(32)))
        XCTAssertEqual(y, Data(x963.suffix(32)))
    }

    // MARK: - Attestation object

    func testAttestationObjectStructure() throws {
        let (key, credentialID) = try fixedRegistrationFixture()
        let attestation = PasskeyCrypto.buildAttestationObject(
            relyingPartyID: "example.com",
            credentialID: credentialID,
            privateKey: key
        )

        var expectedHeader = Data([0xA3])
        expectedHeader.append(Data([0x63]) + Data("fmt".utf8))
        expectedHeader.append(Data([0x64]) + Data("none".utf8))
        expectedHeader.append(Data([0x67]) + Data("attStmt".utf8))
        expectedHeader.append(Data([0xA0]))
        expectedHeader.append(Data([0x68]) + Data("authData".utf8))
        expectedHeader.append(Data([0x58, 0xA4]))
        XCTAssertEqual(attestation.prefix(expectedHeader.count), expectedHeader)

        let embeddedAuthData = attestation.subdata(in: expectedHeader.count..<attestation.count)
        let standaloneAuthData = PasskeyCrypto.buildRegistrationAuthenticatorData(
            relyingPartyID: "example.com",
            credentialID: credentialID,
            publicKey: key.publicKey
        )
        XCTAssertEqual(embeddedAuthData, standaloneAuthData)
    }

    func testRegistrationCredentialMatchesEmbeddedCredentialID() throws {
        let (key, credentialID) = try fixedRegistrationFixture()
        let attestation = PasskeyCrypto.buildAttestationObject(
            relyingPartyID: "example.com",
            credentialID: credentialID,
            privateKey: key
        )
        let credential = ASPasskeyRegistrationCredential(
            relyingParty: "example.com",
            clientDataHash: Data(SHA256.hash(data: Data("client-data".utf8))),
            credentialID: credentialID,
            attestationObject: attestation
        )

        // authData starts after the 30-byte CBOR map header; credID lives at
        // authData offsets 55..<87 (see layout test above).
        let embeddedCredentialID = attestation.subdata(in: (30 + 55)..<(30 + 87))
        XCTAssertEqual(credential.credentialID, embeddedCredentialID)
        XCTAssertEqual(credential.credentialID, credentialID)
    }

    // MARK: - Registration round-trip

    func testRegistrationRoundTripSignsVerifiableAssertion() throws {
        let key = PasskeyCrypto.generatePrivateKey()
        let pem = key.pemRepresentation

        let parsed = try PasskeyCrypto.privateKey(fromPEM: pem)
        XCTAssertEqual(parsed.publicKey.x963Representation, key.publicKey.x963Representation)

        let clientDataHash = Data(SHA256.hash(data: Data("registration-round-trip".utf8)))
        let (authData, signature) = try PasskeyCrypto.signAssertion(
            relyingPartyID: "example.com",
            clientDataHash: clientDataHash,
            privateKey: parsed
        )

        var signedData = authData
        signedData.append(clientDataHash)
        XCTAssertTrue(
            try key.publicKey.isValidSignature(
                P256.Signing.ECDSASignature(derRepresentation: signature),
                for: signedData
            )
        )
    }

    // MARK: - Helpers

    /// Encode a P256 private key as PKCS#8 PEM.
    private func pemEncode(_ key: P256.Signing.PrivateKey) -> String {
        let derData = key.derRepresentation
        let base64 = derData.base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----"
    }
}
