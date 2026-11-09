import CommonCrypto
import CryptoKit
import Foundation
import KeeForgeTwofish

/// Composite keys and the cryptographic primitives the container uses.
public enum KDBXCrypto {
    public enum CryptoError: Error, Equatable, Sendable {
        case invalidKey
        case encryptionFailed
        case decryptionFailed
        case hmacMismatch
        case unsupportedCipher(Data)
        case unsupportedKDF(KDBXKeyDerivation.Unsupported)
        case compressionFailed
        case decompressionFailed
    }

    // MARK: - Composite Key

    /// The composite key for a password alone: SHA-256 of SHA-256 of its UTF-8
    /// bytes, or SHA-256 of nothing for an empty password.
    public static func compositeKey(password: String) -> SymmetricKey {
        var preKey = Data(capacity: 32)
        defer { SecureWipe.wipe(&preKey) }
        appendPasswordHash(password, to: &preKey)
        return preKey.withUnsafeBytes { SymmetricKey(data: CryptoKit.SHA256.hash(data: $0)) }
    }

    /// The composite key for a password and/or key file:
    /// `SHA256(SHA256(password) || keyFileKey)`, skipping absent parts.
    public static func compositeKey(password: String?, keyFileData: Data?) throws -> SymmetricKey {
        let preKey = try preKey(password: password, keyFileData: keyFileData)
        return preKey.withUnsafeBytes { SymmetricKey(data: CryptoKit.SHA256.hash(data: $0)) }
    }

    /// The concatenated key components `compositeKey` hashes, kept apart so a
    /// hardware challenge-response can be appended first.
    public static func preKey(password: String?, keyFileData: Data?) throws -> SymmetricKey {
        var preKey = Data(capacity: 64)
        defer { SecureWipe.wipe(&preKey) }

        if let password {
            appendPasswordHash(password, to: &preKey)
        }
        if let keyFileData {
            var keyFileKey = try KDBXKeyFile.key(from: keyFileData)
            defer { SecureWipe.wipe(&keyFileKey) }
            preKey.append(keyFileKey)
        }

        return SymmetricKey(data: preKey)
    }

    /// An empty password contributes nothing, as in KeePass.
    private static func appendPasswordHash(_ password: String, to preKey: inout Data) {
        guard !password.isEmpty else { return }
        var passwordBytes = Data(password.utf8)
        defer { SecureWipe.wipe(&passwordBytes) }
        var passwordHash = sha256(passwordBytes)
        defer { SecureWipe.wipe(&passwordHash) }
        preKey.append(passwordHash)
    }

    // MARK: - Hashes

    static func sha256(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }

    static func sha512(_ data: Data) -> Data {
        Data(CryptoKit.SHA512.hash(data: data))
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(CryptoKit.HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    // MARK: - AES-256-CBC

    static func decryptAES256CBC(data: Data, key: Data, iv: Data) throws -> Data {
        guard let output = aes256CBC(CCOperation(kCCDecrypt), data: data, key: key, iv: iv) else {
            throw CryptoError.decryptionFailed
        }
        return output
    }

    static func encryptAES256CBC(data: Data, key: Data, iv: Data) throws -> Data {
        guard let output = aes256CBC(CCOperation(kCCEncrypt), data: data, key: key, iv: iv) else {
            throw CryptoError.encryptionFailed
        }
        return output
    }

    /// Decryption strips PKCS#7 padding here: CommonCrypto on macOS 27 accepts
    /// misaligned input and invalid padding without an error.
    private static func aes256CBC(_ operation: CCOperation, data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { return nil }
        let decrypting = operation == CCOperation(kCCDecrypt)
        if decrypting {
            guard !data.isEmpty, data.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }
        }

        let outLength = data.count + kCCBlockSizeAES128
        var output = Data(count: outLength)
        var bytesWritten = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(decrypting ? 0 : kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outLength,
                            &bytesWritten
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = bytesWritten
        if decrypting {
            guard let padding = output.last.map(Int.init), (1...kCCBlockSizeAES128).contains(padding),
                  output.suffix(padding).allSatisfy({ $0 == UInt8(padding) }) else { return nil }
            output.removeLast(padding)
        }
        return output
    }

    // MARK: - Twofish-256-CBC

    static func decryptTwofish256CBC(data: Data, key: Data, iv: Data) throws -> Data {
        do {
            return try TwofishCBC.decrypt(data, key: key, iv: iv)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    static func encryptTwofish256CBC(data: Data, key: Data, iv: Data) throws -> Data {
        do {
            return try TwofishCBC.encrypt(data, key: key, iv: iv)
        } catch {
            throw CryptoError.encryptionFailed
        }
    }

    // MARK: - ChaCha20

    /// Raw, unauthenticated ChaCha20, which CryptoKit does not expose. XOR-based,
    /// so encrypting and decrypting are the same operation.
    static func chaCha20(data: Data, key: Data, nonce: Data) throws -> Data {
        guard key.count == ChaCha20Keystream.keyLength, nonce.count == ChaCha20Keystream.nonceLength else {
            throw CryptoError.invalidKey
        }
        var keystream = ChaCha20Keystream(key: key, nonce: nonce)
        defer { keystream.wipe() }
        return keystream.xor(data)
    }

    /// The one ChaCha20 implementation: the outer cipher and the KDBX 4 inner
    /// random stream both run through it.
    ///
    /// The inner random stream is a single keystream spanning every protected
    /// value in document order, so callers keep one instance alive and feed it
    /// values one at a time; block boundaries fall wherever they fall.
    struct ChaCha20Keystream {
        static let keyLength = 32
        static let nonceLength = 12

        private var initialState: [UInt32]
        private var counter: UInt32 = 0
        private var block: [UInt8] = []
        private var blockOffset = 0

        /// `key` and `nonce` must be 32 and 12 bytes.
        init(key: Data, nonce: Data) {
            precondition(key.count == Self.keyLength && nonce.count == Self.nonceLength)
            var state = [UInt32](repeating: 0, count: 16)
            // "expand 32-byte k"
            state[0] = 0x61707865
            state[1] = 0x3320646e
            state[2] = 0x79622d32
            state[3] = 0x6b206574
            key.withUnsafeBytes { pointer in
                for index in 0..<8 {
                    state[4 + index] = pointer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian
                }
            }
            nonce.withUnsafeBytes { pointer in
                for index in 0..<3 {
                    state[13 + index] = pointer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian
                }
            }
            initialState = state
        }

        /// Zeroes the key words and the buffered keystream block; the stream is unusable afterwards.
        mutating func wipe() {
            SecureWipe.wipe(&initialState)
            SecureWipe.wipe(&block)
            blockOffset = block.count
        }

        mutating func xor(_ data: Data) -> Data {
            var output = [UInt8](repeating: 0, count: data.count)
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                var readOffset = 0
                while readOffset < data.count {
                    if blockOffset >= block.count {
                        block = Self.block(initialState: initialState, counter: counter)
                        blockOffset = 0
                        counter &+= 1
                    }

                    let chunkLength = min(data.count - readOffset, block.count - blockOffset)
                    for index in 0..<chunkLength {
                        output[readOffset + index] = input[readOffset + index] ^ block[blockOffset + index]
                    }
                    readOffset += chunkLength
                    blockOffset += chunkLength
                }
            }
            return Data(output)
        }

        private static func block(initialState: [UInt32], counter: UInt32) -> [UInt8] {
            var state = initialState
            state[12] = counter
            defer { SecureWipe.wipe(&state) }

            var working = state
            defer { SecureWipe.wipe(&working) }
            for _ in 0..<10 {
                quarterRound(&working, 0, 4, 8, 12)
                quarterRound(&working, 1, 5, 9, 13)
                quarterRound(&working, 2, 6, 10, 14)
                quarterRound(&working, 3, 7, 11, 15)
                quarterRound(&working, 0, 5, 10, 15)
                quarterRound(&working, 1, 6, 11, 12)
                quarterRound(&working, 2, 7, 8, 13)
                quarterRound(&working, 3, 4, 9, 14)
            }
            for index in 0..<16 { working[index] = working[index] &+ state[index] }

            var block: [UInt8] = []
            block.reserveCapacity(64)
            for word in working {
                var littleEndian = word.littleEndian
                Swift.withUnsafeBytes(of: &littleEndian) { block.append(contentsOf: $0) }
            }
            return block
        }

        private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 16) | (s[d] >> 16)
            s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 12) | (s[b] >> 20)
            s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 8) | (s[d] >> 24)
            s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 7) | (s[b] >> 25)
        }
    }
}
