import Foundation
import CryptoKit
import CommonCrypto
import KeeForgeTwofish
import zlib
import argon2

struct KDFDescriptor: Equatable, Sendable {
    let identifier: String
    let displayName: String

    var userFacingDescription: String {
        switch identifier {
        case "missing UUID":
            return String(localized: "The database is missing key derivation metadata.")
        case "missing salt":
            return String(localized: "The database is missing key derivation salt data.")
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

    /// Supported Argon2 version bytes; construction from a raw header value is
    /// the single validation point for the "V" parameter.
    enum Version: UInt32, Sendable {
        case v10 = 0x10
        case v13 = 0x13
    }

    /// Derive key using Argon2d or Argon2id
    static func hash(
        password: SymmetricKey,
        salt: Data,
        timeCost: UInt32,
        memoryCost: UInt32, // in KiB
        parallelism: UInt32,
        hashLength: Int = 32,
        version: Version,
        variant: Argon2Variant
    ) throws -> Data {
        let type: argon2_type = switch variant {
        case .d: Argon2_d
        case .id: Argon2_id
        }

        var output = [UInt8](repeating: 0, count: hashLength)
        defer { SecureWipe.wipe(&output) }

        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    argon2_hash(
                        timeCost,
                        memoryCost,
                        parallelism,
                        passwordBytes.baseAddress,
                        passwordBytes.count,
                        saltBytes.baseAddress,
                        saltBytes.count,
                        outputBytes.baseAddress,
                        outputBytes.count,
                        nil,
                        0,
                        type,
                        version.rawValue
                    )
                }
            }
        }

        guard status == Int32(ARGON2_OK.rawValue) else {
            throw Argon2Error.hashFailed(status)
        }
        return Data(output)
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
            case .invalidKey: String(localized: "Invalid master key")
            case .encryptionFailed: String(localized: "Encryption failed")
            case .decryptionFailed: String(localized: "Decryption failed — wrong password?")
            case .hmacMismatch: String(localized: "HMAC verification failed — file corrupted or wrong password")
            case .unsupportedCipher(let c): String(localized: "Unsupported cipher: \(c)")
            case .unsupportedKDF(let descriptor): String(localized: "Unsupported key derivation function: \(descriptor.userFacingDescription)")
            case .compressionFailed: String(localized: "Compression failed")
            case .decompressionFailed: String(localized: "Decompression failed")
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
    static func compositeKey(password: String) -> SymmetricKey {
        guard password.isEmpty == false else { return SymmetricKey(data: sha256(Data())) }
        var passwordBytes = Data(password.utf8)
        defer { SecureWipe.wipe(&passwordBytes) }
        var passwordHash = sha256(passwordBytes)
        defer { SecureWipe.wipe(&passwordHash) }
        return SymmetricKey(data: CryptoKit.SHA256.hash(data: passwordHash))
    }

    /// Build the composite key from password and/or key file data.
    ///
    /// ```
    /// preKey = []
    /// if password: preKey += SHA256(password_utf8)
    /// if keyFile:  preKey += processKeyFile(keyFileData)
    /// compositeKey = SHA256(preKey)
    /// ```
    static func compositeKey(password: String?, keyFileData: Data?) throws -> SymmetricKey {
        var preKey = Data(capacity: 64)
        defer { SecureWipe.wipe(&preKey) }

        if let password, !password.isEmpty {
            var passwordBytes = Data(password.utf8)
            defer { SecureWipe.wipe(&passwordBytes) }
            var pwdHash = sha256(passwordBytes)
            defer { SecureWipe.wipe(&pwdHash) }
            preKey.append(pwdHash)
        }

        if let keyFileData {
            var keyFileKey = try KeyFileProcessor.processKeyFile(keyFileData)
            defer { SecureWipe.wipe(&keyFileKey) }
            preKey.append(keyFileKey)
        }

        return SymmetricKey(data: CryptoKit.SHA256.hash(data: preKey))
    }

    // MARK: - AES-KDF

    static func transformKeyAESKDF(compositeKey: SymmetricKey, seed: Data, rounds: UInt64) throws -> Data {
        guard compositeKey.bitCount == kCCKeySizeAES256 * 8, seed.count == kCCKeySizeAES256 else {
            throw CryptoError.invalidKey
        }

        var derived = compositeKey.withUnsafeBytes { [UInt8]($0) }
        defer { SecureWipe.wipe(&derived) }
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

        return Data(CryptoKit.SHA256.hash(data: derived))
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

    // MARK: - Twofish-256-CBC Encrypt/Decrypt

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

    // MARK: - ChaCha20 Encrypt/Decrypt

    static func decryptChaCha20(data: Data, key: Data, nonce: Data) throws -> Data {
        guard key.count == 32, nonce.count == 12 else {
            throw CryptoError.decryptionFailed
        }

        return chacha20Stream(key: key, nonce: nonce, data: data)
    }

    static func encryptChaCha20(data: Data, key: Data, nonce: Data) throws -> Data {
        guard key.count == 32, nonce.count == 12 else {
            throw CryptoError.encryptionFailed
        }

        return chacha20Stream(key: key, nonce: nonce, data: data)
    }

    // MARK: - ChaCha20 stream cipher (inner random stream)

    /// KDBX uses raw, unauthenticated ChaCha20 here, which CryptoKit does not expose.
    /// ChaCha20 is XOR-based, so encrypt and decrypt are the same operation.
    static func chacha20Stream(key: Data, nonce: Data, data: Data) -> Data {
        guard var keystream = ChaCha20Keystream(key: key, nonce: nonce) else { return data }
        defer { keystream.wipe() }
        return keystream.xor(data)
    }

    /// The one ChaCha20 implementation in the app: outer cipher, KDBX4 inner
    /// random stream decode, and protected-field re-encryption on write all
    /// run through it.
    ///
    /// The inner random stream is a single keystream spanning every protected
    /// value in document order, so those callers keep one instance alive and
    /// feed it values one at a time; block boundaries fall wherever they fall.
    struct ChaCha20Keystream {
        private var initialState: [UInt32]
        private var counter: UInt32 = 0
        private var block: [UInt8] = []
        private var blockOffset = 0

        init?(key: Data, nonce: Data) {
            guard let state = KDBXCrypto.chacha20InitialState(key: key, nonce: nonce) else { return nil }
            initialState = state
        }

        /// Zeroes the key words and the buffered keystream block; the stream is unusable afterwards.
        mutating func wipe() {
            SecureWipe.wipe(&initialState)
            SecureWipe.wipe(&block)
            blockOffset = block.count
        }

        mutating func xor(_ data: Data) -> Data {
            guard !data.isEmpty else { return data }

            var output = [UInt8](repeating: 0, count: data.count)
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                var readOffset = 0
                while readOffset < data.count {
                    if blockOffset >= block.count {
                        block = KDBXCrypto.chacha20Block(initialState: initialState, counter: counter)
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
    }

    private static func chacha20InitialState(key: Data, nonce: Data) -> [UInt32]? {
        guard key.count == 32, nonce.count == 12 else { return nil }

        var state = [UInt32](repeating: 0, count: 16)
        // "expand 32-byte k"
        state[0] = 0x61707865
        state[1] = 0x3320646e
        state[2] = 0x79622d32
        state[3] = 0x6b206574

        key.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            for index in 0..<8 {
                state[4 + index] = pointer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian
            }
        }

        nonce.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            for index in 0..<3 {
                state[13 + index] = pointer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian
            }
        }

        return state
    }

    private static func chacha20Block(initialState: [UInt32], counter: UInt32) -> [UInt8] {
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
            withUnsafeBytes(of: &littleEndian) { bytes in
                block.append(contentsOf: bytes)
            }
        }
        return block
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
