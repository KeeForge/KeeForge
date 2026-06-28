import Foundation
import CryptoKit
import CommonCrypto
import zlib
import Argon2Swift

struct KDFDescriptor: Equatable, Sendable {
    let identifier: String
    let displayName: String

    var userFacingDescription: String {
        switch identifier {
        case "missing UUID":
            return "The database is missing key derivation metadata."
        case "missing salt":
            return "The database is missing key derivation salt data."
        default:
            return displayName
        }
    }
}

// MARK: - Argon2

enum Argon2Variant: UInt32, Sendable {
    case d = 0    // Argon2d
    case id = 2   // Argon2id
}

enum Argon2 {
    enum Argon2Error: Error {
        case hashFailed(Int32)
    }

    /// Derive key using Argon2d or Argon2id
    static func hash(
        password: Data,
        salt: Data,
        timeCost: UInt32,
        memoryCost: UInt32, // in KiB
        parallelism: UInt32,
        hashLength: Int = 32,
        variant: Argon2Variant
    ) throws -> Data {
        let type: Argon2Type = switch variant {
        case .d:
            .d
        case .id:
            .id
        }

        do {
            let result = try Argon2Swift.hashPasswordBytes(
                password: password,
                salt: Salt(bytes: salt),
                iterations: Int(timeCost),
                memory: Int(memoryCost),
                parallelism: Int(parallelism),
                length: hashLength,
                type: type,
                version: .V13
            )
            return result.hashData()
        } catch let error as Argon2SwiftException {
            throw Argon2Error.hashFailed(error.errorCode.rawValue)
        } catch {
            throw Argon2Error.hashFailed(-1)
        }
    }
}

// MARK: - KDBXCrypto

enum KDBXCrypto {
    enum CryptoError: Error, LocalizedError {
        case invalidKey
        case encryptionFailed
        case decryptionFailed
        case hmacMismatch
        case unsupportedCipher(String)
        case unsupportedKDF(KDFDescriptor)
        case compressionFailed
        case decompressionFailed

        var errorDescription: String? {
            switch self {
            case .invalidKey: "Invalid master key"
            case .encryptionFailed: "Encryption failed"
            case .decryptionFailed: "Decryption failed — wrong password?"
            case .hmacMismatch: "HMAC verification failed — file corrupted or wrong password"
            case .unsupportedCipher(let c): "Unsupported cipher: \(c)"
            case .unsupportedKDF(let descriptor): "Unsupported key derivation function: \(descriptor.userFacingDescription)"
            case .compressionFailed: "Compression failed"
            case .decompressionFailed: "Decompression failed"
            }
        }
    }

    // MARK: - SHA-256

    static func sha256(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }

    static func sha512(_ data: Data) -> Data {
        Data(CryptoKit.SHA512.hash(data: data))
    }

    // MARK: - HMAC-SHA256

    static func hmacSHA256(key: Data, data: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        return Data(CryptoKit.HMAC<SHA256>.authenticationCode(for: data, using: symKey))
    }

    // MARK: - Composite Key

    /// Build the composite key from master password (hash of hash)
    static func compositeKey(password: String) -> Data {
        compositeKey(password: password, keyFileData: nil)
    }

    /// Build the composite key from password and/or key file data.
    ///
    /// ```
    /// preKey = []
    /// if password: preKey += SHA256(password_utf8)
    /// if keyFile:  preKey += processKeyFile(keyFileData)
    /// compositeKey = SHA256(preKey)
    /// ```
    static func compositeKey(password: String?, keyFileData: Data?) -> Data {
        var preKey = Data()

        if let password, !password.isEmpty {
            let pwdHash = sha256(Data(password.utf8))
            preKey.append(pwdHash)
        }

        if let keyFileData {
            if let keyFileKey = try? KeyFileProcessor.processKeyFile(keyFileData) {
                preKey.append(keyFileKey)
            }
        }

        return sha256(preKey)
    }

    // MARK: - AES-KDF

    static func transformKeyAESKDF(compositeKey: Data, seed: Data, rounds: UInt64) throws -> Data {
        guard compositeKey.count == kCCKeySizeAES256, seed.count == kCCKeySizeAES256 else {
            throw CryptoError.invalidKey
        }

        var derived = [UInt8](compositeKey)
        let keyBytes = [UInt8](seed)
        let cryptor = try makeAESECBEncryptor(key: keyBytes)
        defer { CCCryptorRelease(cryptor) }

        let blockByteCount = derived.count
        let updateStatus = derived.withUnsafeMutableBytes { derivedPtr in
            var remainingRounds = rounds
            var bytesMoved = 0

            while remainingRounds > 0 {
                let status = CCCryptorUpdate(
                    cryptor,
                    derivedPtr.baseAddress,
                    blockByteCount,
                    derivedPtr.baseAddress,
                    blockByteCount,
                    &bytesMoved
                )

                if status != kCCSuccess || bytesMoved != blockByteCount {
                    return status
                }

                remainingRounds -= 1
            }

            return CCCryptorStatus(kCCSuccess)
        }

        guard updateStatus == kCCSuccess else {
            throw CryptoError.encryptionFailed
        }

        var finalBytesMoved = 0
        let finalStatus = CCCryptorFinal(cryptor, nil, 0, &finalBytesMoved)
        guard finalStatus == kCCSuccess, finalBytesMoved == 0 else {
            throw CryptoError.encryptionFailed
        }

        return sha256(Data(derived))
    }

    private static func makeAESECBEncryptor(key: [UInt8]) throws -> CCCryptorRef {
        guard key.count == kCCKeySizeAES256 else {
            throw CryptoError.invalidKey
        }

        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt),
                CCMode(kCCModeECB),
                CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding),
                nil,
                keyPtr.baseAddress,
                key.count,
                nil,
                0,
                0,
                CCModeOptions(),
                &cryptor
            )
        }

        guard status == kCCSuccess, let cryptor else {
            throw CryptoError.encryptionFailed
        }

        return cryptor
    }

    private static func aesECBEncryptBlock(_ block: some DataProtocol, key: some DataProtocol) throws -> Data {
        let blockData = Data(block)
        guard blockData.count == kCCBlockSizeAES128 else {
            throw CryptoError.invalidKey
        }

        let cryptor = try makeAESECBEncryptor(key: [UInt8](key))
        defer { CCCryptorRelease(cryptor) }

        var outData = Data(count: kCCBlockSizeAES128)
        var bytesWritten = 0
        let outLength = outData.count

        let status = blockData.withUnsafeBytes { dataPtr in
            outData.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(
                    cryptor,
                    dataPtr.baseAddress,
                    blockData.count,
                    outPtr.baseAddress,
                    outLength,
                    &bytesWritten
                )
            }
        }

        guard status == kCCSuccess, bytesWritten == kCCBlockSizeAES128 else {
            throw CryptoError.encryptionFailed
        }

        var finalBytesWritten = 0
        let finalStatus = CCCryptorFinal(cryptor, nil, 0, &finalBytesWritten)
        guard finalStatus == kCCSuccess, finalBytesWritten == 0 else {
            throw CryptoError.encryptionFailed
        }

        return outData.prefix(kCCBlockSizeAES128)
    }

    // MARK: - AES-256-CBC Decrypt

    static func decryptAES256CBC(data: Data, key: Data, iv: Data) throws -> Data {
        let outLength = data.count + kCCBlockSizeAES128
        var outData = Data(count: outLength)
        var bytesWritten: Int = 0

        let status = outData.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
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

        guard status == kCCSuccess else { throw CryptoError.decryptionFailed }
        outData.count = bytesWritten
        return outData
    }

    // MARK: - AES-256-CBC Encrypt

    static func encryptAES256CBC(data: Data, key: Data, iv: Data) throws -> Data {
        let outLength = data.count + kCCBlockSizeAES128
        var outData = Data(count: outLength)
        var bytesWritten: Int = 0

        let status = outData.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
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

        guard status == kCCSuccess else { throw CryptoError.encryptionFailed }
        outData.count = bytesWritten
        return outData
    }

    // MARK: - ChaCha20-Poly1305 Decrypt (CryptoKit)

    static func decryptChaCha20Poly1305(data: Data, key: Data, nonce: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        // KDBX uses ChaCha20 combined box: nonce(12) + ciphertext + tag(16)
        // But the caller gives us raw ciphertext — we handle differently
        // In KDBX4, outer encryption uses 12-byte nonce from header
        guard nonce.count == 12 else { throw CryptoError.decryptionFailed }

        // Last 16 bytes are the Poly1305 tag
        guard data.count > 16 else { throw CryptoError.decryptionFailed }
        let ciphertext = data.prefix(data.count - 16)
        let tag = data.suffix(16)

        do {
            let sealedBox = try CryptoKit.ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try Data(ChaChaPoly.open(sealedBox, using: symKey))
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    // MARK: - ChaCha20-Poly1305 Encrypt (CryptoKit)

    static func encryptChaCha20Poly1305(data: Data, key: Data, nonce: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        guard nonce.count == 12 else { throw CryptoError.encryptionFailed }

        do {
            let sealedBox = try ChaChaPoly.seal(
                data,
                using: symKey,
                nonce: ChaChaPoly.Nonce(data: nonce)
            )

            var encrypted = Data()
            encrypted.append(sealedBox.ciphertext)
            encrypted.append(sealedBox.tag)
            return encrypted
        } catch {
            throw CryptoError.encryptionFailed
        }
    }

    // MARK: - ChaCha20 stream cipher (inner random stream)

    static func chacha20Stream(key: Data, nonce: Data, data: Data) -> Data {
        // ChaCha20 is XOR-based; encrypt == decrypt
        // Use CommonCrypto / raw implementation for stream-only (no Poly1305)
        // CryptoKit only supports ChaCha20-Poly1305 AEAD, so we use CryptoSwift or manual
        // For inner stream, KDBX uses raw ChaCha20 without authentication
        return chacha20XOR(key: key, nonce: nonce, data: data)
    }

    /// Raw ChaCha20 quarter-round based implementation for inner stream cipher
    private static func chacha20XOR(key: Data, nonce: Data, data: Data) -> Data {
        guard key.count == 32, nonce.count == 12 else { return data }

        var state = [UInt32](repeating: 0, count: 16)
        // "expand 32-byte k"
        state[0] = 0x61707865
        state[1] = 0x3320646e
        state[2] = 0x79622d32
        state[3] = 0x6b206574

        key.withUnsafeBytes { ptr in
            for i in 0..<8 {
                state[4 + i] = ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
            }
        }

        state[12] = 0 // counter
        nonce.withUnsafeBytes { ptr in
            for i in 0..<3 {
                state[13 + i] = ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
            }
        }

        var output = Data(count: data.count)
        var offset = 0

        while offset < data.count {
            var working = state
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
            for i in 0..<16 { working[i] = working[i] &+ state[i] }

            let blockBytes = working.withUnsafeBytes { Data($0) }
            let remaining = min(64, data.count - offset)
            for i in 0..<remaining {
                output[offset + i] = data[offset + i] ^ blockBytes[i]
            }

            offset += 64
            state[12] &+= 1
        }

        return output
    }

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 16) | (s[d] >> 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 12) | (s[b] >> 20)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 8) | (s[d] >> 24)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 7) | (s[b] >> 25)
    }

    // MARK: - GZip Decompression

    static func gunzip(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw CryptoError.decompressionFailed }
        let modes: [Int32] = [MAX_WBITS + 16, MAX_WBITS, -MAX_WBITS]
        for mode in modes {
            if let output = try? inflateStream(data: data, windowBits: mode), !output.isEmpty {
                return output
            }
        }
        throw CryptoError.decompressionFailed
    }

    private static func inflateStream(data: Data, windowBits: Int32) throws -> Data {
        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            windowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw CryptoError.decompressionFailed
        }
        defer {
            inflateEnd(&stream)
        }

        let maxDecompressedSize = 256 * 1024 * 1024 // 256 MB

        return try data.withUnsafeBytes { rawInput in
            guard let inputBase = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                throw CryptoError.decompressionFailed
            }

            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            var output = Data()
            var outBuffer = [UInt8](repeating: 0, count: 64 * 1024)

            while true {
                let status = outBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = outBuffer.count - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: outBuffer.prefix(produced))
                }

                if output.count > maxDecompressedSize {
                    throw CryptoError.decompressionFailed
                }

                if status == Z_STREAM_END {
                    break
                }
                guard status == Z_OK else {
                    throw CryptoError.decompressionFailed
                }
                if produced == 0 && stream.avail_in == 0 {
                    throw CryptoError.decompressionFailed
                }
            }

            return output
        }
    }

    // MARK: - GZip Compression

    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw CryptoError.compressionFailed
        }
        defer {
            deflateEnd(&stream)
        }

        return try data.withUnsafeBytes { rawInput in
            if !data.isEmpty {
                guard let inputBase = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                    throw CryptoError.compressionFailed
                }
                stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            } else {
                stream.next_in = nil
            }
            stream.avail_in = uInt(data.count)

            var output = Data()
            var outBuffer = [UInt8](repeating: 0, count: 64 * 1024)

            while true {
                let status = outBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return deflate(&stream, Z_FINISH)
                }

                let produced = outBuffer.count - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: outBuffer.prefix(produced))
                }

                if status == Z_STREAM_END {
                    break
                }

                guard status == Z_OK else {
                    throw CryptoError.compressionFailed
                }
            }

            return output
        }
    }
}
