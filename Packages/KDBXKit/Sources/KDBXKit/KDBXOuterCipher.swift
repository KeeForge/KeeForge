import Foundation

/// Supported outer payload ciphers for KeePass databases.
///
/// Headers continue to retain their raw UUID bytes so unknown/plugin ciphers
/// can be diagnosed without being silently rewritten.
public enum KDBXOuterCipher: Equatable, Sendable {
    case aes256CBC
    case chacha20
    case twofish256CBC

    public init?(uuid: Data) {
        switch uuid {
        case KDBXContainer.aesCipherUUID:
            self = .aes256CBC
        case KDBXContainer.chachaCipherUUID:
            self = .chacha20
        case KDBXContainer.twofishCipherUUID:
            self = .twofish256CBC
        default:
            return nil
        }
    }

    public var uuid: Data {
        switch self {
        case .aes256CBC:
            KDBXContainer.aesCipherUUID
        case .chacha20:
            KDBXContainer.chachaCipherUUID
        case .twofish256CBC:
            KDBXContainer.twofishCipherUUID
        }
    }

    public var displayName: String {
        switch self {
        case .aes256CBC:
            "AES-256"
        case .chacha20:
            "ChaCha20"
        case .twofish256CBC:
            "Twofish-256-CBC"
        }
    }

    public var encryptionIVLength: Int {
        switch self {
        case .aes256CBC, .twofish256CBC:
            16
        case .chacha20:
            12
        }
    }

    public var supportsKDBX3: Bool {
        switch self {
        case .aes256CBC, .twofish256CBC:
            true
        case .chacha20:
            false
        }
    }

    public func decrypt(data: Data, key: Data, iv: Data) throws -> Data {
        switch self {
        case .aes256CBC:
            try KDBXCrypto.decryptAES256CBC(data: data, key: key, iv: iv)
        case .chacha20:
            try KDBXCrypto.decryptChaCha20(data: data, key: key, nonce: iv)
        case .twofish256CBC:
            try KDBXCrypto.decryptTwofish256CBC(data: data, key: key, iv: iv)
        }
    }

    public func encrypt(data: Data, key: Data, iv: Data) throws -> Data {
        switch self {
        case .aes256CBC:
            try KDBXCrypto.encryptAES256CBC(data: data, key: key, iv: iv)
        case .chacha20:
            try KDBXCrypto.encryptChaCha20(data: data, key: key, nonce: iv)
        case .twofish256CBC:
            try KDBXCrypto.encryptTwofish256CBC(data: data, key: key, iv: iv)
        }
    }

    public static func require(uuid: Data) throws -> KDBXOuterCipher {
        guard let cipher = KDBXOuterCipher(uuid: uuid) else {
            throw KDBXCrypto.CryptoError.unsupportedCipher(uuid.hexString)
        }
        return cipher
    }
}
