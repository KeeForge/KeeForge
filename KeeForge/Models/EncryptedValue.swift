import Foundation
import CryptoKit

/// Holds a secret re-encrypted with the per-session AES-GCM key.
/// The original plaintext is only recoverable by calling `decrypt(using:)`.
struct EncryptedValue: Sendable, Hashable {
    /// AES-GCM sealed box: nonce (12) + ciphertext + tag (16), or empty for `.empty`.
    let sealedData: Data
    /// Whether the original plaintext was non-empty.
    let hasValue: Bool

    /// Sentinel for fields where the original plaintext was empty.
    static let empty = EncryptedValue(sealedData: Data(), hasValue: false)

    /// Encrypt a plaintext string with the given session key.
    /// Returns `.empty` if the plaintext is empty.
    static func encrypt(_ plaintext: String, using key: SymmetricKey) throws -> EncryptedValue {
        try encrypt(Data(plaintext.utf8), using: key)
    }

    /// Encrypt arbitrary secret bytes with the per-session key.
    static func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> EncryptedValue {
        guard !plaintext.isEmpty else { return .empty }
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw CryptoKitError.underlyingCoreCryptoError(error: -1)
        }
        return EncryptedValue(sealedData: combined, hasValue: true)
    }

    /// Decrypt to a temporary String. Returns "" if this is `.empty`.
    func decrypt(using key: SymmetricKey) throws -> String {
        String(data: try decryptData(using: key), encoding: .utf8) ?? ""
    }

    /// Decrypt arbitrary secret bytes. Returns empty data for `.empty`.
    func decryptData(using key: SymmetricKey) throws -> Data {
        guard hasValue else { return Data() }
        let box = try AES.GCM.SealedBox(combined: sealedData)
        return try AES.GCM.open(box, using: key)
    }
}
