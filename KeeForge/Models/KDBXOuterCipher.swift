import Foundation

/// Supported outer payload ciphers for KeePass databases.
///
/// Headers continue to retain their raw UUID bytes so unknown/plugin ciphers
/// can be diagnosed without being silently rewritten.
enum KDBXOuterCipher: Equatable, Sendable {
    case aes256CBC
    case chacha20
    case twofish256CBC

    init?(uuid: Data) {
        switch uuid {
        case KDBXParser.aesCipherUUID:
            self = .aes256CBC
        case KDBXParser.chachaCipherUUID:
            self = .chacha20
        case KDBXParser.twofishCipherUUID:
            self = .twofish256CBC
        default:
            return nil
        }
    }

    var uuid: Data {
        switch self {
        case .aes256CBC:
            KDBXParser.aesCipherUUID
        case .chacha20:
            KDBXParser.chachaCipherUUID
        case .twofish256CBC:
            KDBXParser.twofishCipherUUID
        }
    }

    var displayName: String {
        switch self {
        case .aes256CBC:
            "AES-256"
        case .chacha20:
            "ChaCha20"
        case .twofish256CBC:
            "Twofish-256-CBC"
        }
    }

    var encryptionIVLength: Int {
        switch self {
        case .aes256CBC, .twofish256CBC:
            16
        case .chacha20:
            12
        }
    }

    var supportsKDBX3: Bool {
        switch self {
        case .aes256CBC, .twofish256CBC:
            true
        case .chacha20:
            false
        }
    }

    func decrypt(data: Data, key: Data, iv: Data) throws -> Data {
        switch self {
        case .aes256CBC:
            try KDBXCrypto.decryptAES256CBC(data: data, key: key, iv: iv)
        case .chacha20:
            try KDBXCrypto.decryptChaCha20(data: data, key: key, nonce: iv)
        case .twofish256CBC:
            try KDBXCrypto.decryptTwofish256CBC(data: data, key: key, iv: iv)
        }
    }

    func encrypt(data: Data, key: Data, iv: Data) throws -> Data {
        switch self {
        case .aes256CBC:
            try KDBXCrypto.encryptAES256CBC(data: data, key: key, iv: iv)
        case .chacha20:
            try KDBXCrypto.encryptChaCha20(data: data, key: key, nonce: iv)
        case .twofish256CBC:
            try KDBXCrypto.encryptTwofish256CBC(data: data, key: key, iv: iv)
        }
    }

    static func require(uuid: Data) throws -> KDBXOuterCipher {
        guard let cipher = KDBXOuterCipher(uuid: uuid) else {
            throw KDBXCrypto.CryptoError.unsupportedCipher(uuid.hexString)
        }
        return cipher
    }
}
