import CryptoKit
import Foundation
import KDBXKit
import Synchronization

/// A YubiKey HMAC-SHA1 challenge-response slot that is part of a database's
/// composite key, and how this device reaches it.
struct HardwareKeyConfiguration: Codable, Hashable, Sendable {
    enum Transport: String, Codable, Sendable, CaseIterable {
        case nfc
        /// The Mac's USB connection to the key's OTP (keyboard) interface.
        case usb

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            switch value {
            case "nfc", "lightning":
                // Preserve database references saved by the 1.17 beta's removed transport.
                self = .nfc
            case "usb":
                self = .usb
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown hardware key transport")
            }
        }
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
    /// The file is not a KDBX 4 database, the only format whose
    /// challenge-response KeePassXC folds in before the KDF.
    case unsupportedDatabase
    case slotNotConfigured
    /// No YubiKey with an OTP interface is plugged in.
    case notConnected
    /// macOS refused access to the key's keyboard interface (Input Monitoring).
    case permissionDenied
    case timedOut
    case disconnected
    /// A write would give the file a KDF salt the session's YubiKey response
    /// did not answer.
    case challengeChanged
    case communicationFailed
}

/// KeePassXC-compatible challenge-response key derivation
/// (`CompositeKey::rawKey(transformSeed)` / `CompositeKey::transform`).
///
/// A composite key made here is valid only with the KDF salt it answered, so
/// it is remembered with its challenge: a save with it keeps that salt
/// instead of rotating it, and refuses to write any other
/// (`kdfSaltRotation(compositeKey:)`, `checkWrite`). Otherwise the file would
/// need a response nobody holds.
enum ChallengeResponseKey {
    private static let challengeLength = 64
    private static let pinnedChallenges = Mutex<[Data: Data]>([:])

    /// The challenge KeePassXC issues for `data`: the KDF salt (the AES-KDF
    /// seed), PKCS#7-padded to 64 bytes so fixed-length and variable-length
    /// slots agree.
    static func challenge(forDatabase data: Data) throws -> Data {
        guard case .kdbx4 = try KDBXContainer.parseFileVersion(from: data) else {
            throw HardwareKeyError.unsupportedDatabase
        }
        // KeePassXC writes KDBX 4 AES-KDF under the legacy UUID and reads it
        // back as its KDBX 4 AES-KDF, which takes the response like Argon2.
        guard let salt = try KDBXContainer.readHeader(from: data).keyDerivation?.salt else {
            throw HardwareKeyError.unsupportedDatabase
        }
        return try challenge(forSalt: salt)
    }

    static func challenge(forSalt salt: Data) throws -> Data {
        guard salt.isEmpty == false, salt.count <= challengeLength else {
            throw HardwareKeyError.unsupportedDatabase
        }
        let padding = challengeLength - salt.count
        var challenge = Data(capacity: challengeLength)
        challenge.append(salt)
        challenge.append(Data(repeating: UInt8(padding), count: padding))
        return challenge
    }

    /// `SHA256(preKey || SHA256(response))`, where `preKey` is
    /// `KDBXCrypto.preKey(password:keyFileData:)` and `response` answered
    /// `challenge`.
    static func compositeKey(preKey: SymmetricKey, response: Data, challenge: Data) -> SymmetricKey {
        var responseHash = FileDigest.sha256(response)
        defer { SecureWipe.wipe(&responseHash) }

        var material = Data(capacity: preKey.bitCount / 8 + responseHash.count)
        defer { SecureWipe.wipe(&material) }
        preKey.withUnsafeBytes { material.append(contentsOf: $0) }
        material.append(responseHash)
        let key = SymmetricKey(data: CryptoKit.SHA256.hash(data: material))
        let fingerprint = fingerprint(of: key)
        pinnedChallenges.withLock { $0[fingerprint] = challenge }
        return key
    }

    /// The challenge `compositeKey` answered, if it came from `compositeKey(preKey:response:challenge:)`.
    static func pinnedChallenge(for compositeKey: SymmetricKey) -> Data? {
        let fingerprint = fingerprint(of: compositeKey)
        return pinnedChallenges.withLock { $0[fingerprint] }
    }

    /// Whether a save with `compositeKey` may give the file a new KDF salt.
    static func kdfSaltRotation(compositeKey: SymmetricKey) -> KDBXContainerWriter.KDFSaltRotation {
        pinnedChallenge(for: compositeKey) == nil ? .rotate : .keep
    }

    /// Throws unless `kdfParameters`, the ones a file is about to be written
    /// with, still answer to a challenge-response key's challenge.
    static func checkWrite(compositeKey: SymmetricKey, kdfParameters: KDBXVariantMap) throws {
        guard let pinned = pinnedChallenge(for: compositeKey) else { return }
        guard let salt = kdfParameters.bytes("S"), (try? challenge(forSalt: salt)) == pinned else {
            throw HardwareKeyError.challengeChanged
        }
    }

    private static func fingerprint(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data(CryptoKit.SHA256.hash(data: $0)) }
    }
}

extension HardwareKeyError: LocalizedError {
    /// Only a save can see `challengeChanged`; unlock failures read from
    /// `DatabaseOpenFailure`.
    var errorDescription: String? {
        guard self == .challengeChanged else { return nil }
        return String(localized: "This save would need a new answer from your YubiKey, so nothing was written. Lock the database, unlock it with your YubiKey, and save again.")
    }
}
