import CryptoKit
import Foundation

/// Cryptographic operations for passkey (WebAuthn) authentication.
enum PasskeyCrypto: Sendable {
    static let assertionFlags: UInt8 = 0x1D
    static let registrationFlags: UInt8 = 0x5D

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

        guard der.count >= 32 else {
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

        // Fallback: if DER is exactly 32 bytes, treat as raw key
        if der.count == 32 {
            return der
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
        case .invalidPEM: "Invalid PEM-encoded private key"
        case .invalidKeyData: "Could not extract EC P-256 key data"
        case .keyCreationFailed: "Failed to create signing key"
        case .signatureFailed: "Failed to sign assertion"
        case .credentialNotFound: "Passkey credential not found"
        case .missingPrivateKey: "Passkey entry is missing the private key"
        }
    }
}
