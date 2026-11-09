import Foundation

/// The payload ciphers this library reads and writes. A header keeps the raw
/// cipher UUID, so an unknown cipher can be reported without being rewritten.
public enum KDBXOuterCipher: Sendable, Hashable, CaseIterable {
    case aes256CBC
    case chaCha20
    case twofish256CBC

    public init?(uuid: Data) {
        guard let cipher = Self.allCases.first(where: { $0.uuid == uuid }) else { return nil }
        self = cipher
    }

    public var uuid: Data {
        switch self {
        case .aes256CBC:
            Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                  0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
        case .chaCha20:
            Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5,
                  0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])
        case .twofish256CBC:
            Data([0xAD, 0x68, 0xF2, 0x9F, 0x57, 0x6F, 0x4B, 0xB9,
                  0xA3, 0x6A, 0xD4, 0x7A, 0xF9, 0x65, 0x34, 0x6C])
        }
    }

    public var displayName: String {
        switch self {
        case .aes256CBC: "AES-256"
        case .chaCha20: "ChaCha20"
        case .twofish256CBC: "Twofish-256-CBC"
        }
    }

    var encryptionIVLength: Int {
        switch self {
        case .aes256CBC, .twofish256CBC: 16
        case .chaCha20: 12
        }
    }

    /// KDBX 3.1 predates ChaCha20 as an outer cipher.
    var supportsKDBX3: Bool {
        self != .chaCha20
    }

    func decrypt(data: Data, key: Data, iv: Data) throws -> Data {
        switch self {
        case .aes256CBC: try KDBXCrypto.decryptAES256CBC(data: data, key: key, iv: iv)
        case .chaCha20: try KDBXCrypto.chaCha20(data: data, key: key, nonce: iv)
        case .twofish256CBC: try KDBXCrypto.decryptTwofish256CBC(data: data, key: key, iv: iv)
        }
    }

    func encrypt(data: Data, key: Data, iv: Data) throws -> Data {
        switch self {
        case .aes256CBC: try KDBXCrypto.encryptAES256CBC(data: data, key: key, iv: iv)
        case .chaCha20: try KDBXCrypto.chaCha20(data: data, key: key, nonce: iv)
        case .twofish256CBC: try KDBXCrypto.encryptTwofish256CBC(data: data, key: key, iv: iv)
        }
    }

    static func require(uuid: Data) throws -> KDBXOuterCipher {
        guard let cipher = KDBXOuterCipher(uuid: uuid) else {
            throw KDBXCrypto.CryptoError.unsupportedCipher(uuid)
        }
        return cipher
    }
}
