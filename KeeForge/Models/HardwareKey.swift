import CryptoKit
import Foundation

/// A YubiKey HMAC-SHA1 challenge-response slot that is part of a database's
/// composite key, and how this device reaches it.
struct HardwareKeyConfiguration: Codable, Hashable, Sendable {
    enum Transport: String, Codable, Sendable, CaseIterable {
        case nfc
        case lightning
    }

    enum Slot: Int, Codable, Sendable, CaseIterable {
        case one = 1
        case two = 2
    }

    var transport: Transport
    var slot: Slot
}

enum HardwareKeyError: Error, Equatable, Sendable {
    case cancelled
    /// This device, target, or platform cannot reach the configured key.
    case unavailable
    /// The file is not a KDBX 4 database with an Argon2 KDF, the only shape
    /// whose challenge-response KeePassXC defines.
    case unsupportedDatabase
    case slotNotConfigured
    case timedOut
    case disconnected
    case communicationFailed
}

/// KeePassXC-compatible challenge-response key derivation
/// (`CompositeKey::rawKey(transformSeed)` / `CompositeKey::transform`).
enum ChallengeResponseKey {
    private static let challengeLength = 64

    /// The challenge KeePassXC issues for `data`: the KDF salt, PKCS#7-padded
    /// to 64 bytes so fixed-length and variable-length slots agree.
    static func challenge(forDatabase data: Data) throws -> Data {
        guard case .kdbx4 = try KDBXParser.parseFileVersion(from: data) else {
            throw HardwareKeyError.unsupportedDatabase
        }
        var reader = DataReader(data: data)
        _ = try KDBXParser.parseVersion(from: &reader)
        let header = try KDBXParser.parseHeader(&reader)

        // KeePassXC folds the response in before the KDF only for these; a
        // KDBX 4 file with the legacy AES-KDF UUID never carries one.
        guard let kdfUUID = header.kdfParameters["$UUID"] as? Data,
              kdfUUID == KDBXParser.argon2dUUID || kdfUUID == KDBXParser.argon2idUUID,
              let salt = header.kdfParameters["S"] as? Data,
              salt.isEmpty == false,
              salt.count <= challengeLength
        else {
            throw HardwareKeyError.unsupportedDatabase
        }

        let padding = challengeLength - salt.count
        var challenge = Data(capacity: challengeLength)
        challenge.append(salt)
        challenge.append(Data(repeating: UInt8(padding), count: padding))
        return challenge
    }

    /// `SHA256(preKey || SHA256(response))`, where `preKey` is
    /// `KDBXCrypto.preKey(password:keyFileData:)`.
    static func compositeKey(preKey: SymmetricKey, response: Data) -> SymmetricKey {
        var responseHash = KDBXCrypto.sha256(response)
        defer { SecureWipe.wipe(&responseHash) }

        var material = Data(capacity: preKey.bitCount / 8 + responseHash.count)
        defer { SecureWipe.wipe(&material) }
        preKey.withUnsafeBytes { material.append(contentsOf: $0) }
        material.append(responseHash)
        return SymmetricKey(data: CryptoKit.SHA256.hash(data: material))
    }
}
