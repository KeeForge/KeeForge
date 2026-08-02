import CryptoKit
import Foundation

/// Cryptographic operations for passkey (WebAuthn) authentication.
enum PasskeyCrypto: Sendable {
    static let assertionFlags: UInt8 = 0x1D
    static let registrationFlags: UInt8 = 0x5D

    /// KeeForge product AAGUID: FF55D8C0-F4FB-4016-9FDD-56DBBD251802 (stable forever).
    static let aaguid = Data([
        0xFF, 0x55, 0xD8, 0xC0, 0xF4, 0xFB, 0x40, 0x16,
        0x9F, 0xDD, 0x56, 0xDB, 0xBD, 0x25, 0x18, 0x02,
    ])

    // MARK: - PEM -> P256

    /// Parse a PEM-encoded EC P-256 private key into a CryptoKit signing key.
    ///
    /// Supports both PKCS#8 (`BEGIN PRIVATE KEY`) and SEC1 (`BEGIN EC PRIVATE KEY`) formats.
    /// KeePassXC stores keys in PKCS#8 PEM format.
    static func privateKey(fromPEM pem: String) throws -> P256.Signing.PrivateKey {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN EC PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END EC PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let derData = Data(base64Encoded: stripped) else {
            throw PasskeyError.invalidPEM
        }

        if let privateKey = try? P256.Signing.PrivateKey(derRepresentation: derData) {
            return privateKey
        }

        let rawKey = try extractP256RawKey(from: derData)

        do {
            return try P256.Signing.PrivateKey(rawRepresentation: rawKey)
        } catch {
            throw PasskeyError.invalidKeyData
        }
    }

    /// Extract the 32-byte raw P-256 private key from DER-encoded data.
    /// Handles both PKCS#8 and SEC1 container formats.
    private static func extractP256RawKey(from der: Data) throws -> Data {
        // PKCS#8 P-256 private key structure:
        //   SEQUENCE {
        //     INTEGER 0
        //     SEQUENCE { OID ecPublicKey, OID prime256v1 }
        //     OCTET STRING containing SEC1 key
        //   }
        //
        // SEC1 EC private key structure:
        //   SEQUENCE {
        //     INTEGER 1
        //     OCTET STRING (32 bytes = raw private key)
        //     [0] OID (optional)
        //     [1] BIT STRING (optional, public key)
        //   }

        if der.count == 32 {
            return der
        }

        guard der.count >= 34 else {
            throw PasskeyError.invalidKeyData
        }

        // Strategy: scan for the 32-byte OCTET STRING containing the raw key.
        // In both PKCS#8 and SEC1, the raw key appears as: 04 20 <32 bytes>
        // We find the LAST occurrence of this pattern that yields a valid key.
        let bytes = [UInt8](der)
        var candidates: [Data] = []

        for i in 0..<(bytes.count - 33) {
            if bytes[i] == 0x04 && bytes[i + 1] == 0x20 && i + 34 <= bytes.count {
                let candidate = Data(bytes[(i + 2)..<(i + 34)])
                candidates.append(candidate)
            }
        }

        // If we found candidates, verify the key is valid by trying to create a P256 key
        for candidate in candidates.reversed() {
            if (try? P256.Signing.PrivateKey(rawRepresentation: candidate)) != nil {
                return candidate
            }
        }

        // Fallback: try using the DER directly with CryptoKit's x963 or DER representations
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) {
            return key.rawRepresentation
        }

        throw PasskeyError.invalidKeyData
    }

    // MARK: - Assertion signing

    /// Sign a WebAuthn assertion (authenticator data + client data hash).
    ///
    /// - Parameters:
    ///   - relyingPartyID: The relying party identifier (used to compute RP ID hash).
    ///   - clientDataHash: The SHA-256 hash of the client data JSON (provided by the system).
    ///   - counter: The signature counter value (KeePassXC always uses 0).
    ///   - privateKey: The P-256 signing key to sign with.
    /// - Returns: A tuple of (authenticatorData, signature).
    static func signAssertion(
        relyingPartyID: String,
        clientDataHash: Data,
        counter: UInt32 = 0,
        privateKey: P256.Signing.PrivateKey
    ) throws -> (authenticatorData: Data, signature: Data) {
        let authenticatorData = buildAuthenticatorData(
            relyingPartyID: relyingPartyID,
            counter: counter
        )

        // The signature is over: authenticatorData || clientDataHash
        var signedData = authenticatorData
        signedData.append(clientDataHash)

        let signature = try privateKey.signature(for: signedData).derRepresentation

        return (authenticatorData, signature)
    }

    /// Build the authenticator data for an assertion.
    ///
    /// Format (37 bytes for assertion):
    ///   - rpIdHash: SHA-256 of RP ID (32 bytes)
    ///   - flags: 1 byte (UP | UV | BE | BS = 0x1D for assertions)
    ///   - signCount: 4 bytes big-endian
    static func buildAuthenticatorData(
        relyingPartyID: String,
        counter: UInt32 = 0,
        flags: UInt8 = assertionFlags
    ) -> Data {
        let rpIdHash = Data(SHA256.hash(data: Data(relyingPartyID.utf8)))
        var data = rpIdHash
        data.append(flags)
        var bigEndianCounter = counter.bigEndian
        data.append(Data(bytes: &bigEndianCounter, count: 4))
        return data
    }

    // MARK: - Registration

    static func generatePrivateKey() -> P256.Signing.PrivateKey {
        P256.Signing.PrivateKey()
    }

    static func generateCredentialID() throws -> Data {
        try SecureRandom.data(count: 32)
    }

    /// Build registration authenticator data with attested credential data.
    ///
    /// Format:
    ///   - rpIdHash: SHA-256 of RP ID (32 bytes)
    ///   - flags: 1 byte (UP | UV | AT | BE | BS = 0x5D)
    ///   - signCount: 4 bytes big-endian, zero
    ///   - AAGUID: 16 bytes
    ///   - credentialID length: 2 bytes big-endian
    ///   - credentialID
    ///   - COSE_Key of the P-256 public key
    static func buildRegistrationAuthenticatorData(
        relyingPartyID: String,
        credentialID: Data,
        publicKey: P256.Signing.PublicKey
    ) -> Data {
        var data = buildAuthenticatorData(
            relyingPartyID: relyingPartyID,
            counter: 0,
            flags: registrationFlags
        )
        data.append(aaguid)
        var credentialIDLength = UInt16(credentialID.count).bigEndian
        data.append(Data(bytes: &credentialIDLength, count: 2))
        data.append(credentialID)
        data.append(coseKey(for: publicKey))
        return data
    }

    /// Build a WebAuthn attestation object with "none" attestation:
    /// CBOR map {"fmt": "none", "attStmt": {}, "authData": bytes} in that key order.
    static func buildAttestationObject(
        relyingPartyID: String,
        credentialID: Data,
        privateKey: P256.Signing.PrivateKey
    ) -> Data {
        let authenticatorData = buildRegistrationAuthenticatorData(
            relyingPartyID: relyingPartyID,
            credentialID: credentialID,
            publicKey: privateKey.publicKey
        )
        var data = CBOR.mapHeader(count: 3)
        data.append(CBOR.textString("fmt"))
        data.append(CBOR.textString("none"))
        data.append(CBOR.textString("attStmt"))
        data.append(CBOR.mapHeader(count: 0))
        data.append(CBOR.textString("authData"))
        data.append(CBOR.byteString(authenticatorData))
        return data
    }

    /// COSE_Key (ES256, P-256) in canonical key order: {1: 2, 3: -7, -1: 1, -2: x, -3: y}.
    /// x and y are taken from the X9.63 representation (0x04 || x || y), 32 bytes each.
    private static func coseKey(for publicKey: P256.Signing.PublicKey) -> Data {
        let x963 = publicKey.x963Representation
        let x = Data(x963.dropFirst(1).prefix(32))
        let y = Data(x963.suffix(32))
        var data = CBOR.mapHeader(count: 5)
        data.append(CBOR.unsigned(1))
        data.append(CBOR.unsigned(2))
        data.append(CBOR.unsigned(3))
        data.append(CBOR.negative(-7))
        data.append(CBOR.negative(-1))
        data.append(CBOR.unsigned(1))
        data.append(CBOR.negative(-2))
        data.append(CBOR.byteString(x))
        data.append(CBOR.negative(-3))
        data.append(CBOR.byteString(y))
        return data
    }

    /// Minimal CBOR encoder covering only what registration output needs.
    /// Map keys are appended pre-ordered by the caller.
    private enum CBOR {
        static func header(major: UInt8, value: UInt64) -> Data {
            switch value {
            case 0..<24:
                Data([major << 5 | UInt8(value)])
            case 24..<0x100:
                Data([major << 5 | 24, UInt8(value)])
            case 0x100..<0x1_0000:
                Data([major << 5 | 25, UInt8(value >> 8), UInt8(value & 0xFF)])
            default:
                Data([
                    major << 5 | 26,
                    UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                    UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
                ])
            }
        }

        static func unsigned(_ value: UInt64) -> Data {
            header(major: 0, value: value)
        }

        static func negative(_ value: Int64) -> Data {
            header(major: 1, value: UInt64(-1 - value))
        }

        static func byteString(_ bytes: Data) -> Data {
            header(major: 2, value: UInt64(bytes.count)) + bytes
        }

        static func textString(_ string: String) -> Data {
            let utf8 = Data(string.utf8)
            return header(major: 3, value: UInt64(utf8.count)) + utf8
        }

        static func mapHeader(count: Int) -> Data {
            header(major: 5, value: UInt64(count))
        }
    }
}

// MARK: - Errors

enum PasskeyError: Error, LocalizedError {
    case invalidPEM
    case invalidKeyData
    case keyCreationFailed
    case signatureFailed
    case credentialNotFound
    case missingPrivateKey

    var errorDescription: String? {
        switch self {
        case .invalidPEM: String(localized: "Invalid PEM-encoded private key")
        case .invalidKeyData: String(localized: "Could not extract EC P-256 key data")
        case .keyCreationFailed: String(localized: "Failed to create signing key")
        case .signatureFailed: String(localized: "Failed to sign assertion")
        case .credentialNotFound: String(localized: "Passkey credential not found")
        case .missingPrivateKey: String(localized: "Passkey entry is missing the private key")
        }
    }
}
