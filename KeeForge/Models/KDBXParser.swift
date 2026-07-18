import Foundation
import CryptoKit

/// Full KDBX 4.x parser — reads header, derives key, decrypts, decompresses, parses XML
enum KDBXParser {
    // MARK: - Constants

    static let kdbxSignature1: UInt32 = 0x9AA2D903
    static let kdbxSignature2: UInt32 = 0xB54BFB67
    static let versionKDBX3: UInt16 = 3
    static let versionKDBX4: UInt16 = 4

    // Cipher UUIDs (16 bytes)
    static let aesCipherUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                                     0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
    static let chachaCipherUUID = Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5,
                                        0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])
    static let twofishCipherUUID = Data([0xAD, 0x68, 0xF2, 0x9F, 0x57, 0x6F, 0x4B, 0xB9,
                                         0xA3, 0x6A, 0xD4, 0x7A, 0xF9, 0x65, 0x34, 0x6C])

    // KDF UUIDs
    static let argon2dUUID = Data([0xEF, 0x63, 0x6D, 0xDF, 0x8C, 0x29, 0x44, 0x4B,
                                   0x91, 0xF7, 0xA9, 0xA4, 0x03, 0xE3, 0x0A, 0x0C])
    static let argon2idUUID = Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73,
                                    0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
    static let aesKDFUUID = Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60,
                                  0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])
    static let aesKDFMaxRounds: UInt64 = 100_000_000

    // Inner random stream IDs
    static let innerStreamNone: UInt32 = 0
    static let innerStreamArcFourVariant: UInt32 = 1
    static let innerStreamSalsa20: UInt32 = 2
    static let innerStreamChaCha20: UInt32 = 3

    // MARK: - Header Fields

    enum HeaderField: UInt8 {
        case endOfHeader = 0
        case cipherID = 2
        case compressionFlags = 3
        case masterSeed = 4
        case encryptionIV = 7
        case kdfParameters = 11
    }

    enum InnerHeaderField: UInt8 {
        case endOfHeader = 0
        case innerRandomStreamID = 1
        case innerRandomStreamKey = 2
        case binary = 3
    }

    enum LegacyHeaderField: UInt8 {
        case endOfHeader = 0
        case cipherID = 2
        case compressionFlags = 3
        case masterSeed = 4
        case transformSeed = 5
        case transformRounds = 6
        case encryptionIV = 7
        case protectedStreamKey = 8
        case streamStartBytes = 9
        case innerRandomStreamID = 10
    }

    enum FileVersion: Equatable, Sendable {
        case kdbx3_1
        case kdbx4(minor: UInt16)

        var majorVersion: UInt16 {
            switch self {
            case .kdbx3_1:
                versionKDBX3
            case .kdbx4:
                versionKDBX4
            }
        }

        var minorVersion: UInt16 {
            switch self {
            case .kdbx3_1:
                1
            case .kdbx4(let minor):
                minor
            }
        }

        var requiresReadOnlyMode: Bool {
            switch self {
            case .kdbx3_1:
                true
            case .kdbx4:
                false
            }
        }
    }

    // MARK: - Parsed Header

    struct UnknownHeaderField: Equatable, Sendable {
        let id: UInt8
        let data: Data
    }

    struct Header: @unchecked Sendable {
        var formatVersion = FileVersion.kdbx4(minor: 0)
        var cipherID = Data()
        var compressionFlags: UInt32 = 0
        var masterSeed = Data()
        var encryptionIV = Data()
        var kdfParameters: [String: Any] = [:]
        var unknownOuterHeaderFields: [UnknownHeaderField] = []
        var headerData = Data() // raw bytes for HMAC check
        var innerStreamID: UInt32 = 0
        var innerStreamKey = Data()
        var innerHeaderBinaryFields: [Data] = []
    }

    // MARK: - Errors

    enum ParseError: Error, LocalizedError, Equatable {
        case invalidSignature
        case unsupportedVersion(UInt16)
        case truncatedFile
        case headerFieldMissing(String)
        case xmlParsingFailed
        case invalidBlockHMAC
        case invalidLegacyBlockHash
        case invalidStreamStartBytes
        case innerHeaderInvalid
        case unsupportedProtectedFieldStream(UInt32)
        case malformedVariantMap
        case kdfParameterOutOfRange(String)

        var errorDescription: String? {
            switch self {
            case .invalidSignature: String(localized: "Not a valid KDBX file")
            case .unsupportedVersion:
                String(localized: "This database uses an older KeePass format that KeeForge does not support yet.")
            case .truncatedFile: String(localized: "File is truncated")
            case .headerFieldMissing(let f): String(localized: "Missing header field: \(f)")
            case .xmlParsingFailed: String(localized: "Failed to parse database XML")
            case .invalidBlockHMAC: String(localized: "Block HMAC invalid — wrong password or corrupted file")
            case .invalidLegacyBlockHash: String(localized: "The database appears corrupted or incomplete.")
            case .invalidStreamStartBytes: String(localized: "Decryption failed — wrong password?")
            case .innerHeaderInvalid: String(localized: "Invalid inner header")
            case .unsupportedProtectedFieldStream: String(localized: "This database uses an unsupported protected-field stream.")
            case .malformedVariantMap: String(localized: "Malformed variant map in header")
            case .kdfParameterOutOfRange(let p): String(localized: "KDF parameter out of range: \(p)")
            }
        }
    }

    // MARK: - Constant-Time Comparison

    /// Compare two Data values in constant time to prevent timing side-channels on HMAC/hash checks.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

    // MARK: - Public API

    /// Parse and decrypt a KDBX 4.x file, returning the root group
    static func parse(data: Data, password: String, sessionKey: SymmetricKey) throws -> KPGroup {
        let compositeKey = KDBXCrypto.compositeKey(password: password)
        return try parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
    }

    static func parseWithMeta(
        data: Data,
        password: String,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let compositeKey = KDBXCrypto.compositeKey(password: password)
        return try parseWithMeta(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        password: String,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: Header) {
        let compositeKey = KDBXCrypto.compositeKey(password: password)
        return try parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
    }

    /// Parse and decrypt with password and/or key file data
    static func parse(data: Data, password: String?, keyFileData: Data?, sessionKey: SymmetricKey) throws -> KPGroup {
        let compositeKey = KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        return try parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
    }

    static func parseWithMeta(
        data: Data,
        password: String?,
        keyFileData: Data?,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let compositeKey = KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        return try parseWithMeta(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        password: String?,
        keyFileData: Data?,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: Header) {
        let compositeKey = KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        return try parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
    }

    static func parse(data: Data, compositeKey: Data, sessionKey: SymmetricKey) throws -> KPGroup {
        try parseWithMeta(data: data, compositeKey: compositeKey, sessionKey: sessionKey).rootGroup
    }

    static func parseWithMeta(
        data: Data,
        compositeKey: Data,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let parsed = try parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
        return (parsed.rootGroup, parsed.meta)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        compositeKey: Data,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: Header) {
        let version = try parseFileVersion(from: data)
        switch version {
        case .kdbx3_1:
            return try parseKDBX3WithMetaAndHeader(
                data: data,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        case .kdbx4:
            return try parseKDBX4WithMetaAndHeader(
                data: data,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        }
    }

    static func parseFileVersion(from data: Data) throws -> FileVersion {
        var reader = DataReader(data: data)

        let sig1 = try reader.readUInt32()
        let sig2 = try reader.readUInt32()
        guard sig1 == kdbxSignature1, sig2 == kdbxSignature2 else {
            throw ParseError.invalidSignature
        }

        let versionMinor = try reader.readUInt16()
        let versionMajor = try reader.readUInt16()

        switch versionMajor {
        case versionKDBX3 where versionMinor == 1:
            return .kdbx3_1
        case versionKDBX4:
            return .kdbx4(minor: versionMinor)
        default:
            throw ParseError.unsupportedVersion(versionMajor)
        }
    }

    private static func parseKDBX4WithMetaAndHeader(
        data: Data,
        compositeKey: Data,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: Header) {
        var reader = DataReader(data: data)

        let version = try parseVersion(from: &reader)
        guard case .kdbx4(let minorVersion) = version else {
            throw ParseError.unsupportedVersion(version.majorVersion)
        }

        let headerStart = 0
        var header = try parseHeader(&reader)
        header.formatVersion = .kdbx4(minor: minorVersion)
        let headerEnd = reader.offset
        let headerBytes = data.subdata(in: headerStart..<headerEnd)
        header.headerData = headerBytes

        // 4. Header SHA-256 and HMAC
        let storedHeaderSHA = try reader.readBytes(32)
        let storedHeaderHMAC = try reader.readBytes(32)

        let computedHeaderSHA = KDBXCrypto.sha256(headerBytes)
        guard constantTimeEqual(storedHeaderSHA, computedHeaderSHA) else {
            throw ParseError.invalidSignature
        }

        // 5. Derive keys
        let transformedKey = try deriveKey(compositeKey: compositeKey, kdfParams: header.kdfParameters)

        // Master key = SHA256(masterSeed + transformedKey)
        var preKey = Data()
        preKey.append(header.masterSeed)
        preKey.append(transformedKey)
        let masterKey = KDBXCrypto.sha256(preKey)

        // HMAC base key
        var hmacPreKey = Data()
        hmacPreKey.append(header.masterSeed)
        hmacPreKey.append(transformedKey)
        hmacPreKey.append(Data([0x01]))
        let hmacBaseKey = KDBXCrypto.sha512(hmacPreKey)

        // Verify header HMAC
        let headerHMACKey = computeBlockHMACKey(blockIndex: UInt64.max, baseKey: hmacBaseKey)
        let computedHeaderHMAC = KDBXCrypto.hmacSHA256(key: headerHMACKey, data: headerBytes)
        guard constantTimeEqual(storedHeaderHMAC, computedHeaderHMAC) else {
            throw KDBXCrypto.CryptoError.hmacMismatch
        }

        // 6. Read and verify HMAC blocks
        let encryptedPayload = try readHMACBlocks(reader: &reader, baseKey: hmacBaseKey)

        // 7. Decrypt payload
        let cipher = try KDBXOuterCipher.require(uuid: header.cipherID)
        let decryptedPayload = try cipher.decrypt(
            data: encryptedPayload,
            key: masterKey,
            iv: header.encryptionIV
        )

        var payloadForInnerHeader = decryptedPayload
        var payloadWasPreDecompressed = false
        if header.compressionFlags == 1, let decompressedPayload = try? KDBXCrypto.gunzip(decryptedPayload) {
            payloadForInnerHeader = decompressedPayload
            payloadWasPreDecompressed = true
        }

        // 8. Parse inner header
        var innerReader = DataReader(data: payloadForInnerHeader)
        let innerHeader = try parseInnerHeader(&innerReader)
        header.innerStreamID = innerHeader.streamID
        header.innerStreamKey = innerHeader.streamKey
        header.innerHeaderBinaryFields = innerHeader.binaryFields

        // Some producers omit the inner header and write payload directly.
        // If we consumed the whole payload without discovering header fields,
        // rewind and treat decrypted bytes as XML/compressed XML.
        let missingInnerHeader = innerReader.offset == payloadForInnerHeader.count &&
            innerHeader.streamID == 0 &&
            innerHeader.streamKey.isEmpty
        if missingInnerHeader {
            innerReader.offset = 0
        }

        // 9. Get remaining data (the XML or compressed XML)
        let innerPayload = payloadForInnerHeader.subdata(in: innerReader.offset..<payloadForInnerHeader.count)
        #if DEBUG
        print("[KDBXParser] decrypted=\(decryptedPayload.count) innerOffset=\(innerReader.offset) innerPayload=\(innerPayload.count) compression=\(header.compressionFlags) preDecompressed=\(payloadWasPreDecompressed) innerHead=\(innerPayload.prefix(8).hexString)")
        #endif

        // 10. Decompress if needed
        let xmlData: Data
        if payloadWasPreDecompressed {
            xmlData = innerPayload
        } else if header.compressionFlags == 1 { // gzip
            if let decompressed = try? KDBXCrypto.gunzip(innerPayload) {
                xmlData = decompressed
            } else if looksLikeXML(innerPayload) {
                // Some producers write plain XML despite compression flag.
                xmlData = innerPayload
            } else {
                throw KDBXCrypto.CryptoError.decompressionFailed
            }
        } else {
            xmlData = innerPayload
        }

        // 11. Parse XML
        let parsed = try parseXML(
            xmlData: xmlData,
            innerStreamKey: innerHeader.streamKey,
            innerStreamID: innerHeader.streamID,
            sessionKey: sessionKey
        )

        return (parsed.rootGroup, parsed.meta, header)
    }

    static func parseVersion(from reader: inout DataReader) throws -> FileVersion {
        let sig1 = try reader.readUInt32()
        let sig2 = try reader.readUInt32()
        guard sig1 == kdbxSignature1, sig2 == kdbxSignature2 else {
            throw ParseError.invalidSignature
        }

        let versionMinor = try reader.readUInt16()
        let versionMajor = try reader.readUInt16()

        switch versionMajor {
        case versionKDBX3 where versionMinor == 1:
            return .kdbx3_1
        case versionKDBX4:
            return .kdbx4(minor: versionMinor)
        default:
            throw ParseError.unsupportedVersion(versionMajor)
        }
    }

    // MARK: - Header Parsing

    static func parseHeader(_ reader: inout DataReader) throws -> Header {
        var header = Header()

        while reader.hasMore {
            let fieldID = try reader.readUInt8()
            let fieldSize = Int(try reader.readUInt32())

            guard let field = HeaderField(rawValue: fieldID) else {
                header.unknownOuterHeaderFields.append(
                    UnknownHeaderField(id: fieldID, data: try reader.readBytes(fieldSize))
                )
                continue
            }

            switch field {
            case .endOfHeader:
                try reader.skip(fieldSize)
                return header
            case .cipherID:
                header.cipherID = try reader.readBytes(fieldSize)
            case .compressionFlags:
                header.compressionFlags = try reader.readUInt32From(fieldSize)
            case .masterSeed:
                header.masterSeed = try reader.readBytes(fieldSize)
            case .encryptionIV:
                header.encryptionIV = try reader.readBytes(fieldSize)
            case .kdfParameters:
                let kdfData = try reader.readBytes(fieldSize)
                header.kdfParameters = try parseVariantMap(kdfData)
            }
        }

        return header
    }

    static func parseInnerHeader(
        _ reader: inout DataReader
    ) throws -> (streamID: UInt32, streamKey: Data, binaryFields: [Data]) {
        var streamID: UInt32 = 0
        var streamKey = Data()
        var binaryFields: [Data] = []

        while reader.hasMore {
            let fieldID = try reader.readUInt8()
            let fieldSize = Int(try reader.readUInt32())

            guard let field = InnerHeaderField(rawValue: fieldID) else {
                try reader.skip(fieldSize)
                continue
            }

            switch field {
            case .endOfHeader:
                try reader.skip(fieldSize)
                return (streamID, streamKey, binaryFields)
            case .innerRandomStreamID:
                streamID = try reader.readUInt32From(fieldSize)
            case .innerRandomStreamKey:
                streamKey = try reader.readBytes(fieldSize)
            case .binary:
                binaryFields.append(try reader.readBytes(fieldSize))
            }
        }

        return (streamID, streamKey, binaryFields)
    }

    // MARK: - Variant Map (KDF Parameters)

    private static func parseVariantMap(_ data: Data) throws -> [String: Any] {
        var reader = DataReader(data: data)
        var result: [String: Any] = [:]

        // Skip version
        let _ = try reader.readUInt16()

        while reader.hasMore {
            let type = try reader.readUInt8()
            if type == 0 { break }

            let keyLen = Int(try reader.readUInt32())
            let key = String(data: try reader.readBytes(keyLen), encoding: .utf8) ?? ""
            let valLen = Int(try reader.readUInt32())
            let valData = try reader.readBytes(valLen)

            switch type {
            case 0x04: // UInt32
                guard valData.count == 4 else { throw ParseError.malformedVariantMap }
                result[key] = valData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            case 0x05: // UInt64
                guard valData.count == 8 else { throw ParseError.malformedVariantMap }
                result[key] = valData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            case 0x08: // Bool
                guard !valData.isEmpty else { throw ParseError.malformedVariantMap }
                result[key] = valData[0] != 0
            case 0x0C: // Int32
                guard valData.count == 4 else { throw ParseError.malformedVariantMap }
                result[key] = valData.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            case 0x0D: // Int64
                guard valData.count == 8 else { throw ParseError.malformedVariantMap }
                result[key] = valData.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
            case 0x18: // String
                result[key] = String(data: valData, encoding: .utf8) ?? ""
            case 0x42: // Byte array
                result[key] = valData
            default:
                result[key] = valData
            }
        }

        return result
    }

    // MARK: - Key Derivation

    static func deriveKey(compositeKey: Data, kdfParams: [String: Any]) throws -> Data {
        guard let uuidData = kdfParams["$UUID"] as? Data else {
            throw KDBXCrypto.CryptoError.unsupportedKDF(KDFDescriptor(identifier: "missing UUID", displayName: "Unknown KDF"))
        }

        if uuidData == aesKDFUUID {
            guard let seed = kdfParams["S"] as? Data else {
                throw KDBXCrypto.CryptoError.unsupportedKDF(KDFDescriptor(identifier: "missing salt", displayName: "AES-KDF"))
            }
            let rounds = (kdfParams["R"] as? UInt64) ?? 0
            guard rounds >= 1, rounds <= aesKDFMaxRounds else {
                throw ParseError.kdfParameterOutOfRange("rounds \(rounds) not in 1...\(aesKDFMaxRounds)")
            }
            return try KDBXCrypto.transformKeyAESKDF(compositeKey: compositeKey, seed: seed, rounds: rounds)
        }

        let variant: Argon2Variant
        if uuidData == argon2dUUID {
            variant = .d
        } else if uuidData == argon2idUUID {
            variant = .id
        } else {
            throw KDBXCrypto.CryptoError.unsupportedKDF(
                KDFDescriptor(identifier: uuidData.hexString, displayName: "Unknown KDF (\(uuidData.hexString))")
            )
        }

        guard let salt = kdfParams["S"] as? Data else {
            throw KDBXCrypto.CryptoError.unsupportedKDF(KDFDescriptor(identifier: "missing salt", displayName: variant == .d ? "Argon2d" : "Argon2id"))
        }

        let iterations = (kdfParams["I"] as? UInt64) ?? 3
        let memory = (kdfParams["M"] as? UInt64) ?? (64 * 1024 * 1024) // bytes
        let parallelism = (kdfParams["P"] as? UInt32) ?? 1

        // Bounds checks — these params are attacker-controlled (from file header)
        guard iterations >= 1, iterations <= 1_000 else {
            throw ParseError.kdfParameterOutOfRange("iterations \(iterations) not in 1...1000")
        }
        guard memory >= 8192, memory <= 4_294_967_296 else {
            throw ParseError.kdfParameterOutOfRange("memory \(memory) bytes not in 8192...4294967296")
        }
        guard parallelism >= 1, parallelism <= 256 else {
            throw ParseError.kdfParameterOutOfRange("parallelism \(parallelism) not in 1...256")
        }

        // Safe UInt32 conversions — fail closed on overflow
        guard let iterationsU32 = UInt32(exactly: iterations) else {
            throw ParseError.kdfParameterOutOfRange("iterations \(iterations) overflows UInt32")
        }
        let memoryKiB = memory / 1024
        guard let memoryCostU32 = UInt32(exactly: memoryKiB) else {
            throw ParseError.kdfParameterOutOfRange("memory \(memory) bytes overflows UInt32 KiB")
        }

        return try Argon2.hash(
            password: compositeKey,
            salt: salt,
            timeCost: iterationsU32,
            memoryCost: memoryCostU32,
            parallelism: parallelism,
            hashLength: 32,
            variant: variant
        )
    }

    // MARK: - HMAC Block Reading

    static func readHMACBlocks(reader: inout DataReader, baseKey: Data) throws -> Data {
        var result = Data()
        var blockIndex: UInt64 = 0

        while true {
            let storedHMAC = try reader.readBytes(32)
            let blockSizeRaw = try reader.readInt32()

            guard blockSizeRaw >= 0 else { throw ParseError.truncatedFile }

            if blockSizeRaw == 0 {
                // Final block — verify HMAC of empty block
                let hmacKey = computeBlockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
                var msg = Data()
                msg.append(withUInt64: blockIndex)
                msg.append(withInt32: 0)
                let computed = KDBXCrypto.hmacSHA256(key: hmacKey, data: msg)
                guard constantTimeEqual(storedHMAC, computed) else { throw ParseError.invalidBlockHMAC }
                break
            }

            let blockData = try reader.readBytes(Int(blockSizeRaw))

            let hmacKey = computeBlockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
            var msg = Data()
            msg.append(withUInt64: blockIndex)
            msg.append(withInt32: blockSizeRaw)
            msg.append(blockData)
            let computed = KDBXCrypto.hmacSHA256(key: hmacKey, data: msg)
            guard constantTimeEqual(storedHMAC, computed) else { throw ParseError.invalidBlockHMAC }

            result.append(blockData)
            blockIndex += 1
        }

        return result
    }

    static func computeBlockHMACKey(blockIndex: UInt64, baseKey: Data) -> Data {
        var indexData = Data()
        indexData.append(withUInt64: blockIndex)
        return KDBXCrypto.sha512(indexData + baseKey)
    }

    // MARK: - XML Parsing

    static func parseXML(
        xmlData: Data,
        innerStreamKey: Data,
        innerStreamID: UInt32,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        try validateSupportedProtectedFieldStream(innerStreamID)
        let parser = KDBXXMLParser(
            data: xmlData,
            innerStreamKey: innerStreamKey,
            innerStreamID: innerStreamID,
            sessionKey: sessionKey
        )
        return try parser.parse()
    }

    private static func looksLikeXML(_ data: Data) -> Bool {
        let utf8BOM = Data([0xEF, 0xBB, 0xBF])
        let trimmed: Data
        if data.starts(with: utf8BOM) {
            trimmed = Data(data.dropFirst(utf8BOM.count))
        } else {
            trimmed = data
        }
        return trimmed.starts(with: Data("<?xml".utf8)) || trimmed.starts(with: Data("<KeePassFile".utf8))
    }
}

// MARK: - Data Reader Helper

struct DataReader {
    let data: Data
    var offset: Int = 0

    var hasMore: Bool { offset < data.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw KDBXParser.ParseError.truncatedFile }
        let val = data[offset]
        offset += 1
        return val
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(2)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    mutating func readInt32() throws -> Int32 {
        let bytes = try readBytes(4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
    }

    mutating func readUInt32From(_ size: Int) throws -> UInt32 {
        let bytes = try readBytes(size)
        guard bytes.count >= 4 else { throw KDBXParser.ParseError.truncatedFile }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw KDBXParser.ParseError.truncatedFile
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw KDBXParser.ParseError.truncatedFile
        }
        offset += count
    }
}

// MARK: - Data Extensions

extension Data {
    mutating func append(withUInt64 value: UInt64) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 8))
    }

    mutating func append(withInt32 value: Int32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - XML Parser

final class KDBXXMLParser: NSObject, XMLParserDelegate {
    private struct GroupBuilder {
        var id = UUID()
        var name = ""
        var iconID = 48
        var customIconUUID: UUID?
        var entries: [KPEntry] = []
        var groups: [KPGroup] = []
        var isExpanded = true
        var creationTime: Date?
        var lastModificationTime: Date?
        var unknownXML = OpaqueXMLNodes.empty
        var knownChildCount = 0
        var timesKnownChildCount = 0

        func build(recycleBinUUID: UUID? = nil) -> KPGroup {
            KPGroup(
                id: id,
                name: name,
                iconID: iconID,
                customIconUUID: customIconUUID,
                entries: entries,
                groups: groups,
                isExpanded: isExpanded,
                creationTime: creationTime,
                lastModificationTime: lastModificationTime,
                recycleBinUUID: recycleBinUUID,
                unknownXML: unknownXML
            )
        }
    }

    private struct MetaBuilder {
        var recycleBinUUID: UUID?
        var hasRecycleBinUUIDElement = false
        var maintenanceHistoryDays: Int?
        var historyMaxItems: Int?
        var historyMaxSize: Int64?
        var unknownXML = OpaqueXMLNodes.empty
        var knownChildCount = 0
        var customIcons: [UUID: Data] = [:]

        func build() -> KPMeta {
            KPMeta(
                recycleBinUUID: recycleBinUUID,
                hasRecycleBinUUIDElement: hasRecycleBinUUIDElement,
                maintenanceHistoryDays: maintenanceHistoryDays,
                historyMaxItems: historyMaxItems,
                historyMaxSize: historyMaxSize,
                unknownXML: unknownXML,
                customIcons: customIcons
            )
        }
    }

    private struct XMLCaptureElement {
        let name: String
        let attributes: [String: String]
        var content = ""

        mutating func append(text: String) {
            content += Self.escape(text)
        }

        mutating func append(rawXML: String) {
            content += rawXML
        }

        func render() -> String {
            let renderedAttributes = attributes
                .sorted { $0.key < $1.key }
                .map { " \($0.key)=\"\(Self.escapeAttribute($0.value))\"" }
                .joined()
            return "<\(name)\(renderedAttributes)>\(content)</\(name)>"
        }

        private static func escape(_ text: String) -> String {
            text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        private static func escapeAttribute(_ text: String) -> String {
            escape(text)
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
    }

    private struct ProtectedValueCipher {
        private enum Mode {
            case none
            case salsa20(initialState: [UInt32])
            case chacha20(initialState: [UInt32])
        }

        private let mode: Mode
        private var salsaCounterLow: UInt32 = 0
        private var salsaCounterHigh: UInt32 = 0
        private var chachaCounter: UInt32 = 0
        private var keystreamBlock: [UInt8] = []
        private var offset = 0

        init(streamID: UInt32, innerStreamKey: Data) {
            switch streamID {
            case KDBXParser.innerStreamSalsa20:
                let key = KDBXCrypto.sha256(innerStreamKey)
                let nonce = Data([0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A])
                var state = [UInt32](repeating: 0, count: 16)
                state[0] = 0x61707865
                state[5] = 0x3320646e
                state[10] = 0x79622d32
                state[15] = 0x6b206574

                key.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    for i in 0..<4 {
                        state[1 + i] = ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                        state[11 + i] = ptr.loadUnaligned(fromByteOffset: (i + 4) * 4, as: UInt32.self).littleEndian
                    }
                }

                nonce.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    state[6] = ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
                    state[7] = ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
                }

                mode = .salsa20(initialState: state)

            case KDBXParser.innerStreamChaCha20:
                let keyHash = KDBXCrypto.sha512(innerStreamKey)
                var state = [UInt32](repeating: 0, count: 16)
                state[0] = 0x61707865
                state[1] = 0x3320646e
                state[2] = 0x79622d32
                state[3] = 0x6b206574

                Data(keyHash.prefix(32)).withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    for i in 0..<8 {
                        state[4 + i] = ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                    }
                }

                Data(keyHash[32..<44]).withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    for i in 0..<3 {
                        state[13 + i] = ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                    }
                }

                mode = .chacha20(initialState: state)

            default:
                mode = .none
            }
        }

        mutating func xor(_ encrypted: Data) -> Data {
            guard !encrypted.isEmpty else { return encrypted }

            switch mode {
            case .none:
                return encrypted
            case .salsa20(let initialState):
                return xorSalsa20(encrypted, initialState: initialState)
            case .chacha20(let initialState):
                return xorChaCha20(encrypted, initialState: initialState)
            }
        }

        private mutating func xorSalsa20(_ encrypted: Data, initialState: [UInt32]) -> Data {
            var decrypted = [UInt8](repeating: 0, count: encrypted.count)

            encrypted.withUnsafeBytes { (encryptedPtr: UnsafeRawBufferPointer) in
                var readOffset = 0
                while readOffset < encrypted.count {
                    if offset >= keystreamBlock.count {
                        keystreamBlock = Self.makeSalsa20Block(
                            initialState: initialState,
                            counterLow: salsaCounterLow,
                            counterHigh: salsaCounterHigh
                        )
                        offset = 0
                        let nextLow = salsaCounterLow &+ 1
                        if nextLow == 0 {
                            salsaCounterHigh &+= 1
                        }
                        salsaCounterLow = nextLow
                    }

                    let chunkLength = min(encrypted.count - readOffset, keystreamBlock.count - offset)
                    for index in 0..<chunkLength {
                        decrypted[readOffset + index] = encryptedPtr[readOffset + index] ^ keystreamBlock[offset + index]
                    }
                    readOffset += chunkLength
                    offset += chunkLength
                }
            }

            return Data(decrypted)
        }

        private mutating func xorChaCha20(_ encrypted: Data, initialState: [UInt32]) -> Data {
            var decrypted = [UInt8](repeating: 0, count: encrypted.count)

            encrypted.withUnsafeBytes { (encryptedPtr: UnsafeRawBufferPointer) in
                var readOffset = 0
                while readOffset < encrypted.count {
                    if offset >= keystreamBlock.count {
                        keystreamBlock = Self.makeChaCha20Block(initialState: initialState, counter: chachaCounter)
                        offset = 0
                        chachaCounter &+= 1
                    }

                    let chunkLength = min(encrypted.count - readOffset, keystreamBlock.count - offset)
                    for index in 0..<chunkLength {
                        decrypted[readOffset + index] = encryptedPtr[readOffset + index] ^ keystreamBlock[offset + index]
                    }
                    readOffset += chunkLength
                    offset += chunkLength
                }
            }

            return Data(decrypted)
        }

        private static func makeSalsa20Block(
            initialState: [UInt32],
            counterLow: UInt32,
            counterHigh: UInt32
        ) -> [UInt8] {
            var state = initialState
            state[8] = counterLow
            state[9] = counterHigh

            var working = state
            for _ in 0..<10 {
                salsaQuarterRound(&working, 0, 4, 8, 12)
                salsaQuarterRound(&working, 5, 9, 13, 1)
                salsaQuarterRound(&working, 10, 14, 2, 6)
                salsaQuarterRound(&working, 15, 3, 7, 11)

                salsaQuarterRound(&working, 0, 1, 2, 3)
                salsaQuarterRound(&working, 5, 6, 7, 4)
                salsaQuarterRound(&working, 10, 11, 8, 9)
                salsaQuarterRound(&working, 15, 12, 13, 14)
            }

            for i in 0..<16 {
                working[i] = working[i] &+ state[i]
            }

            return serializeWords(working)
        }

        private static func makeChaCha20Block(initialState: [UInt32], counter: UInt32) -> [UInt8] {
            var state = initialState
            state[12] = counter

            var working = state
            for _ in 0..<10 {
                chachaQuarterRound(&working, 0, 4, 8, 12)
                chachaQuarterRound(&working, 1, 5, 9, 13)
                chachaQuarterRound(&working, 2, 6, 10, 14)
                chachaQuarterRound(&working, 3, 7, 11, 15)
                chachaQuarterRound(&working, 0, 5, 10, 15)
                chachaQuarterRound(&working, 1, 6, 11, 12)
                chachaQuarterRound(&working, 2, 7, 8, 13)
                chachaQuarterRound(&working, 3, 4, 9, 14)
            }

            for i in 0..<16 {
                working[i] = working[i] &+ state[i]
            }

            return serializeWords(working)
        }

        private static func salsaQuarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            state[b] ^= rotl(state[a] &+ state[d], by: 7)
            state[c] ^= rotl(state[b] &+ state[a], by: 9)
            state[d] ^= rotl(state[c] &+ state[b], by: 13)
            state[a] ^= rotl(state[d] &+ state[c], by: 18)
        }

        private static func chachaQuarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = rotl(state[d], by: 16)
            state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = rotl(state[b], by: 12)
            state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = rotl(state[d], by: 8)
            state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = rotl(state[b], by: 7)
        }

        private static func rotl(_ value: UInt32, by amount: UInt32) -> UInt32 {
            (value << amount) | (value >> (32 - amount))
        }

        private static func serializeWords(_ words: [UInt32]) -> [UInt8] {
            var block: [UInt8] = []
            block.reserveCapacity(64)
            for word in words {
                var little = word.littleEndian
                withUnsafeBytes(of: &little) { bytes in
                    block.append(contentsOf: bytes)
                }
            }
            return block
        }
    }

    private let data: Data
    private let innerStreamKey: Data
    private let innerStreamID: UInt32
    private let sessionKey: SymmetricKey

    private var groupStack: [GroupBuilder] = []
    private var currentMeta = MetaBuilder()
    private var entryStack: [EntryBuilder] = []
    private var currentKey = ""
    private var currentValue = ""
    private var currentText = ""
    private var isProtected = false
    private var currentStringWasProtected = false
    private var inValue = false
    private var inKey = false
    private var currentBinaryRef: Int?
    private var currentBinaryRefWasParsable = true
    private var historyDepth = 0
    private var inMeta = false
    private var inCustomIcons = false
    private var currentCustomIconUUID: UUID?
    private var currentCustomIconData: Data?
    private var captureStack: [XMLCaptureElement] = []

    private var protectedValueCipher: ProtectedValueCipher

    private var rootEntries: [KPEntry] = []
    private var rootGroups: [KPGroup] = []
    private var rootUnknownXML = OpaqueXMLNodes.empty
    private var rootKnownChildCount = 0
    private var meta = KPMeta()

    // DeletedObjects tracking
    private var inDeletedObjects = false
    private var inDeletedObject = false
    private var currentDeletedObjectUUID: UUID?
    private var currentDeletedObjectTime: Date?
    private var parsedDeletedObjects: [KPDeletedObject] = []
    private static let syntheticRootUUID = nullUUID

    private var currentEntry: EntryBuilder? {
        entryStack.last
    }

    init(data: Data, innerStreamKey: Data, innerStreamID: UInt32, sessionKey: SymmetricKey) {
        self.data = data
        self.innerStreamKey = innerStreamKey
        self.innerStreamID = innerStreamID
        self.sessionKey = sessionKey
        self.protectedValueCipher = ProtectedValueCipher(
            streamID: innerStreamID,
            innerStreamKey: innerStreamKey
        )
    }

    func parse() throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw KDBXParser.ParseError.xmlParsingFailed
        }
        let root = KPGroup(
            id: Self.syntheticRootUUID,
            name: "Root",
            entries: rootEntries,
            groups: rootGroups,
            recycleBinUUID: meta.recycleBinUUID,
            unknownXML: rootUnknownXML
        )
        var completedMeta = meta
        completedMeta.deletedObjects = parsedDeletedObjects
        return (root, completedMeta)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""
        captureStack.append(XMLCaptureElement(name: elementName, attributes: attributes))

        switch elementName {
        case "Meta":
            inMeta = true
            currentMeta = MetaBuilder()

        case "CustomIcons" where inMeta:
            inCustomIcons = true

        case "Icon" where inCustomIcons:
            currentCustomIconUUID = nil
            currentCustomIconData = nil

        case "Group":
            groupStack.append(GroupBuilder())

        case "History":
            historyDepth += 1
            currentEntry?.historyKnownChildCount = 0

        case "Entry":
            entryStack.append(EntryBuilder())

        case "DeletedObjects":
            inDeletedObjects = true

        case "DeletedObject" where inDeletedObjects:
            inDeletedObject = true
            currentDeletedObjectUUID = nil
            currentDeletedObjectTime = nil

        case "String":
            currentKey = ""
            currentValue = ""
            isProtected = false
            currentStringWasProtected = false

        case "Binary":
            currentKey = ""
            currentBinaryRef = nil
            currentBinaryRefWasParsable = true

        case "Key":
            inKey = true

        case "Value":
            inValue = true
            currentStringWasProtected = attributes["Protected"]?.lowercased() == "true"
            isProtected = currentStringWasProtected
            if let refAttribute = attributes["Ref"] {
                if let ref = Int(refAttribute) {
                    currentBinaryRef = ref
                } else {
                    currentBinaryRefWasParsable = false
                }
            }

        case "Times":
            if let currentEntry {
                currentEntry.timesKnownChildCount = 0
            } else if !inMeta, let index = groupStack.indices.last {
                groupStack[index].timesKnownChildCount = 0
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
        if let index = captureStack.indices.last {
            captureStack[index].append(text: string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let captured = captureStack.removeLast()
        var capturedXML = captured.render()
        let parentName = captureStack.last?.name
        let grandparentName = captureStack.count >= 2 ? captureStack[captureStack.count - 2].name : nil

        switch elementName {
        case "Meta":
            inMeta = false
            meta = currentMeta.build()

        case "RecycleBinUUID":
            if inMeta {
                currentMeta.hasRecycleBinUUIDElement = true
                currentMeta.recycleBinUUID = parseKPUUID(currentText)
            }

        case "MaintenanceHistoryDays":
            if inMeta {
                currentMeta.maintenanceHistoryDays = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case "HistoryMaxItems":
            if inMeta {
                currentMeta.historyMaxItems = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case "HistoryMaxSize":
            if inMeta {
                currentMeta.historyMaxSize = Int64(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case "CustomIcons":
            inCustomIcons = false

        case "Icon" where inCustomIcons:
            if let uuid = currentCustomIconUUID, let data = currentCustomIconData {
                currentMeta.customIcons[uuid] = data
            }
            currentCustomIconUUID = nil
            currentCustomIconData = nil

        case "UUID" where inCustomIcons:
            currentCustomIconUUID = parseKPUUID(currentText)

        case "Data" where inCustomIcons && parentName == "Icon":
            currentCustomIconData = Data(
                base64Encoded: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                options: .ignoreUnknownCharacters
            )

        case "CustomIconUUID":
            if let currentEntry {
                currentEntry.customIconUUID = parseKPUUID(currentText)
            } else if !inMeta, let index = groupStack.indices.last {
                groupStack[index].customIconUUID = parseKPUUID(currentText)
            }

        case "Group":
            let group = groupStack.removeLast().build()
            if let index = groupStack.indices.last {
                groupStack[index].groups.append(group)
            } else {
                rootGroups.append(group)
            }

        case "DeletedObjects":
            inDeletedObjects = false

        case "DeletedObject" where inDeletedObjects:
            if let uuid = currentDeletedObjectUUID, let time = currentDeletedObjectTime {
                parsedDeletedObjects.append(KPDeletedObject(uuid: uuid, deletionTime: time))
            }
            inDeletedObject = false

        case "UUID" where inDeletedObject:
            currentDeletedObjectUUID = parseKPUUID(currentText)

        case "DeletionTime" where inDeletedObject:
            currentDeletedObjectTime = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines))

        case "History":
            historyDepth = max(0, historyDepth - 1)

        case "Entry":
            guard let builder = entryStack.popLast() else { return }
            let entry = builder.build(sessionKey: sessionKey)
            if isInsideHistory(), let parentEntry = currentEntry {
                parentEntry.history.append(entry)
            } else if let index = groupStack.indices.last {
                groupStack[index].entries.append(entry)
            } else {
                rootEntries.append(entry)
            }
            if entryStack.isEmpty {
                currentKey = ""
                currentValue = ""
            }

        case "Name":
            if !inMeta, currentEntry == nil, let index = groupStack.indices.last {
                groupStack[index].name = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

        case "IconID":
            let val = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if let currentEntry {
                currentEntry.iconID = val
            } else if let index = groupStack.indices.last {
                groupStack[index].iconID = val
            }

        case "Key":
            if inKey {
                currentKey = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                inKey = false
            }

        case "Value":
            if inValue {
                // Preserve leading/trailing whitespace in stored values — a
                // username or custom field may intentionally contain spaces,
                // and trimming here silently destroys that data. Only the
                // base64 ciphertext of a protected value needs trimming before
                // decoding.
                if isProtected {
                    let base64 = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let decoded = Data(base64Encoded: base64) {
                        currentValue = decryptProtectedValue(decoded)
                    } else {
                        currentValue = currentText
                    }
                } else {
                    currentValue = currentText
                }
                inValue = false
            }

        case "String":
            if let entry = currentEntry {
                if currentStringWasProtected, !currentKey.isEmpty {
                    entry.protectedStringKeys.insert(currentKey)
                }
                switch currentKey {
                case "Title": entry.title = currentValue
                case "UserName": entry.username = currentValue
                case "Password": entry.password = currentValue
                case "URL": entry.url = currentValue
                case "Notes": entry.notes = currentValue
                case "otp": entry.otpURL = currentValue
                default:
                    if !currentKey.isEmpty {
                        entry.customFields[currentKey] = currentValue
                    }
                }
            }

        case "Binary":
            if let entry = currentEntry, currentBinaryRefWasParsable, let ref = currentBinaryRef {
                entry.attachments.append(
                    KPAttachment(name: currentKey, ref: ref, insertionIndex: entry.attachmentAnchorChildCount)
                )
            } else {
                // Malformed or missing Ref: keep the element as opaque XML
                // rather than failing the parse.
                currentBinaryRefWasParsable = false
            }

        case "Times":
            break // handled by sub-elements

        case "CreationTime":
            let date = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            if let currentEntry {
                currentEntry.creationTime = date
            } else if let index = groupStack.indices.last {
                groupStack[index].creationTime = date
            }

        case "LastModificationTime":
            let date = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            if let currentEntry {
                currentEntry.lastModificationTime = date
            } else if let index = groupStack.indices.last {
                groupStack[index].lastModificationTime = date
            }

        case "ExpiryTime" where parentName == "Times":
            if let currentEntry {
                currentEntry.expiryTime = parseKPDate(
                    currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

        case "Expires" where parentName == "Times":
            if let currentEntry {
                currentEntry.expires = currentText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "true"
            }

        case "Tags":
            if let entry = currentEntry {
                // Track element presence separately from content so that an
                // empty `<Tags></Tags>` element round-trips instead of being
                // silently dropped on save.
                entry.hasTagsElement = true
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    entry.tags = trimmed.components(separatedBy: CharacterSet([",", ";"])).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty }
                }
            }

        case "UUID":
            if let entry = currentEntry, !inMeta {
                if let uuid = parseKPUUID(currentText) {
                    entry.uuid = uuid
                }
            } else if currentEntry == nil, !inMeta, let index = groupStack.indices.last {
                if let uuid = parseKPUUID(currentText) {
                    groupStack[index].id = uuid
                }
            }

        case "IsExpanded":
            if let index = groupStack.indices.last {
                groupStack[index].isExpanded = currentText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "false"
            }

        default:
            break
        }

        if elementName == "Value", currentStringWasProtected {
            capturedXML = renderProtectedValueElement(attributes: captured.attributes, plaintext: currentValue)
        }

        recordOpaqueXML(
            elementName: elementName,
            parentName: parentName,
            grandparentName: grandparentName,
            xml: capturedXML
        )

        if let index = captureStack.indices.last {
            captureStack[index].append(rawXML: capturedXML)
        }
    }

    // MARK: - Protected Value Decryption

    private func decryptProtectedValue(_ encrypted: Data) -> String {
        let decrypted = protectedValueCipher.xor(encrypted)
        return String(data: decrypted, encoding: .utf8) ?? ""
    }

    private func isInsideHistory() -> Bool {
        historyDepth > 0
    }

    private func renderProtectedValueElement(attributes: [String: String], plaintext: String) -> String {
        let renderedAttributes = attributes
            .sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(escapeAttribute($0.value))\"" }
            .joined()
        return "<Value\(renderedAttributes)>\(escapeText(plaintext))</Value>"
    }

    private func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeAttribute(_ text: String) -> String {
        escapeText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func recordOpaqueXML(
        elementName: String,
        parentName: String?,
        grandparentName: String?,
        xml: String
    ) {
        switch parentName {
        case "Root":
            if elementName == "Entry" || elementName == "Group" || elementName == "DeletedObjects" {
                rootKnownChildCount += 1
            } else {
                rootUnknownXML.append(xml: xml, insertionIndex: rootKnownChildCount)
            }

        case "Meta":
            if elementName == "RecycleBinUUID" {
                currentMeta.knownChildCount += 1
            } else if elementName == "MaintenanceHistoryDays" ||
                        elementName == "HistoryMaxItems" ||
                        elementName == "HistoryMaxSize" {
                currentMeta.knownChildCount += 1
            } else {
                currentMeta.unknownXML.append(xml: xml, insertionIndex: currentMeta.knownChildCount)
            }

        case "Group":
            guard let index = groupStack.indices.last else { return }
            switch elementName {
            case "UUID", "Name", "IconID", "IsExpanded", "Times", "Entry", "Group":
                groupStack[index].knownChildCount += 1
            default:
                groupStack[index].unknownXML.append(
                    xml: xml,
                    insertionIndex: groupStack[index].knownChildCount
                )
            }

        case "Entry":
            guard let entry = currentEntry else { return }
            switch elementName {
            case "UUID", "IconID", "Tags", "Times", "String", "History":
                entry.knownChildCount += 1
                entry.attachmentAnchorChildCount += 1
            case "Binary" where currentBinaryRefWasParsable:
                // Counts toward opaque-XML sibling positioning (knownChildCount)
                // but not toward attachmentAnchorChildCount: the writer's
                // interleaving loop only advances past non-attachment known
                // elements, so attachment insertionIndex must live in that same
                // position space rather than including other attachments.
                entry.knownChildCount += 1
            default:
                entry.unknownXML.append(xml: xml, insertionIndex: entry.knownChildCount)
            }

        case "History":
            guard let entry = currentEntry else { return }
            switch elementName {
            case "Entry":
                entry.historyKnownChildCount += 1
            default:
                entry.unknownXML.append(
                    xml: xml,
                    path: ["History"],
                    insertionIndex: entry.historyKnownChildCount
                )
            }

        case "Times":
            switch grandparentName {
            case "Entry":
                guard let entry = currentEntry else { return }
                switch elementName {
                case "CreationTime", "LastModificationTime":
                    entry.timesKnownChildCount += 1
                default:
                    entry.unknownXML.append(
                        xml: xml,
                        path: ["Times"],
                        insertionIndex: entry.timesKnownChildCount
                    )
                }

            case "Group":
                guard let index = groupStack.indices.last else { return }
                switch elementName {
                case "CreationTime", "LastModificationTime":
                    groupStack[index].timesKnownChildCount += 1
                default:
                    groupStack[index].unknownXML.append(
                        xml: xml,
                        path: ["Times"],
                        insertionIndex: groupStack[index].timesKnownChildCount
                    )
                }

            default:
                break
            }

        default:
            break
        }
    }

    private static let nullUUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))

    private func parseKPUUID(_ string: String) -> UUID? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 16 else { return nil }
        let uuid = data.withUnsafeBytes { ptr -> UUID in
            UUID(uuid: ptr.loadUnaligned(as: uuid_t.self))
        }
        // Null UUID means "not configured"
        return uuid == Self.nullUUID ? nil : uuid
    }

    /// Seconds from Foundation's reference date (2001-01-01 UTC) to the KeePass
    /// epoch (0001-01-01 UTC).  This equals −730 485 days × 86 400 s/day, i.e.
    /// 2 000 Gregorian years containing 485 leap years — matching .NET
    /// `DateTime`'s epoch that the KDBX binary timestamp format is based on.
    private static let kpEpochOffset: TimeInterval = -63_113_904_000

    private func parseKPDate(_ string: String) -> Date? {
        // KDBX4 stores timestamps as 8 bytes of little-endian seconds since
        // year 0001, base64-encoded (always 12 characters with padding).
        // Try this form first — base64 strings can legitimately contain the
        // characters 'T' and '-', so a substring check is not a reliable way
        // to distinguish binary from ISO-8601 form.
        if string.count == 12, let data = Data(base64Encoded: string), data.count == 8 {
            let seconds = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).littleEndian }
            return Date(timeIntervalSinceReferenceDate: Self.kpEpochOffset + TimeInterval(seconds))
        }
        // KDBX 3.x and some KDBX 4 writers use ISO-8601 text form.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Entry Builder

private class EntryBuilder {
    var uuid: UUID?
    var title = ""
    var username = ""
    var password = ""
    var url = ""
    var notes = ""
    var iconID = 0
    var customIconUUID: UUID?
    var tags: [String] = []
    var hasTagsElement = false
    var customFields: [String: String] = [:]
    var protectedStringKeys: Set<String> = []
    var otpURL: String?
    var creationTime: Date?
    var lastModificationTime: Date?
    var expires = false
    var expiryTime: Date?
    var history: [KPEntry] = []
    var unknownXML = OpaqueXMLNodes.empty
    var knownChildCount = 0
    /// Count of non-`Binary` known children seen so far, i.e. the same
    /// position space the writer's `serializeEntry` counter occupies (it
    /// never advances for attachments). Used as `KPAttachment.insertionIndex`
    /// so re-serialization interleaves `<Binary>` at its original position
    /// without attachments polluting each other's recorded index the way a
    /// shared counter would.
    var attachmentAnchorChildCount = 0
    var timesKnownChildCount = 0
    var historyKnownChildCount = 0
    var attachments: [KPAttachment] = []

    func build(sessionKey: SymmetricKey) -> KPEntry {
        let encryptedPassword = (try? EncryptedValue.encrypt(password, using: sessionKey)) ?? .empty
        let totpConfig = buildTOTPConfig(sessionKey: sessionKey)
        // Only the field that actually backs the TOTP config is managed by
        // the serializer; other otp-named fields must stay in customFields
        // so they round-trip.
        let keeOTPFieldName = totpConfig?.keeOTPSource?.fieldName
        return KPEntry(
            id: uuid ?? UUID(),
            title: title,
            username: username,
            password: encryptedPassword,
            url: url,
            notes: notes,
            iconID: iconID,
            customIconUUID: customIconUUID,
            tags: tags,
            hasTagsElement: hasTagsElement,
            customFields: customFields.filter {
                !$0.key.hasPrefix("TimeOtp-") && $0.key != "TOTP Settings" && $0.key != "TOTP Seed"
                    && $0.key != keeOTPFieldName
            },
            totpConfig: totpConfig,
            otpURL: otpURL,
            creationTime: creationTime,
            lastModificationTime: lastModificationTime,
            expires: expires,
            expiryTime: expiryTime,
            history: history,
            unknownXML: unknownXML,
            protectedStringKeys: protectedStringKeys,
            attachments: attachments
        )
    }

    private func buildTOTPConfig(sessionKey: SymmetricKey) -> TOTPConfig? {
        // otpauth:// URI (KeePassXC standard)
        if let otpURL, otpURL.hasPrefix("otpauth://") {
            return parseTOTPFromURI(otpURL, sessionKey: sessionKey)
        }

        // KeePassXC TimeOtp fields
        if let secret = customFields["TimeOtp-Secret-Base32"], !secret.isEmpty {
            let encryptedSecret = (try? EncryptedValue.encrypt(secret, using: sessionKey)) ?? .empty
            let period = Int(customFields["TimeOtp-Period"] ?? "30") ?? 30
            let digits = Int(customFields["TimeOtp-Length"] ?? "6") ?? 6
            let algo = TOTPAlgorithm(rawValue: customFields["TimeOtp-Algorithm"] ?? "SHA1") ?? .sha1
            return TOTPConfig(secret: encryptedSecret, period: period, digits: digits, algorithm: algo)
        }

        // Legacy TOTP Seed / TOTP Settings
        if let seed = customFields["TOTP Seed"], !seed.isEmpty {
            let encryptedSeed = (try? EncryptedValue.encrypt(seed, using: sessionKey)) ?? .empty
            let settings = customFields["TOTP Settings"] ?? "30;6"
            let parts = settings.components(separatedBy: ";")
            let period = Int(parts.first ?? "30") ?? 30
            let digits = Int(parts.count > 1 ? parts[1] : "6") ?? 6
            return TOTPConfig(secret: encryptedSeed, period: period, digits: digits)
        }

        let candidates = [("otp", otpURL), ("OTP", customFields["OTP"]), ("Otp", customFields["Otp"])]
        for (fieldName, value) in candidates where value?.hasPrefix("key=") == true {
            if let value, let config = parseKeeOTPTOTP(value, fieldName: fieldName, sessionKey: sessionKey) {
                return config
            }
        }
        return nil
    }

    private func parseKeeOTPTOTP(_ query: String, fieldName: String, sessionKey: SymmetricKey) -> TOTPConfig? {
        // URLComponents percent-decodes query values but, unlike form decoding,
        // keeps a literal "+" as "+" rather than converting it to a space.
        guard let components = URLComponents(string: "https://keeotp.invalid/?\(query)") else { return nil }
        let mappedNames = Set(["key", "encoding", "type", "step", "size", "otphashmode"])
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard !mappedNames.contains(name) || params[name] == nil,
                  let value = item.value else { return nil }
            if mappedNames.contains(name) { params[name] = value }
        }

        // KeeOtp2 omits parameters that hold their defaults (a plain TOTP
        // entry is just "key=SECRET", and "type" is only written for HOTP),
        // so only `key` is required; the rest are validated when present.
        guard let key = params["key"], !key.isEmpty else { return nil }
        if let type = params["type"], type.uppercased() != "TOTP" { return nil }
        let step: Int
        if let stepValue = params["step"] {
            guard let parsed = Int(stepValue), parsed > 0 else { return nil }
            step = parsed
        } else {
            step = 30
        }
        let size: Int
        if let sizeValue = params["size"] {
            guard let parsed = Int(sizeValue), [6, 8].contains(parsed) else { return nil }
            size = parsed
        } else {
            size = 6
        }
        let algorithm: TOTPAlgorithm
        if let hash = params["otphashmode"] {
            guard let parsed = TOTPAlgorithm(rawValue: hash.uppercased()) else { return nil }
            algorithm = parsed
        } else {
            algorithm = .sha1
        }
        guard let decoded = decodeKeeOTPSecret(key, encoding: params["encoding"] ?? "Base32"), !decoded.isEmpty,
              let encryptedKey = try? EncryptedValue.encrypt(key, using: sessionKey),
              let encryptedDecoded = try? EncryptedValue.encrypt(decoded, using: sessionKey) else { return nil }

        return TOTPConfig(
            secret: encryptedKey,
            decodedSecret: encryptedDecoded,
            keeOTPSource: KeeOTPSource(fieldName: fieldName, rawQuery: query),
            period: step,
            digits: size,
            algorithm: algorithm
        )
    }

    private func decodeKeeOTPSecret(_ key: String, encoding: String) -> Data? {
        switch encoding.lowercased() {
        case "base32":
            guard let normalized = normalizeStrictUnpaddedBase32(key) else { return nil }
            return TOTPGenerator.base32Decode(normalized).flatMap { $0.isEmpty ? nil : $0 }
        case "base64":
            guard let decoded = Data(base64Encoded: key), !decoded.isEmpty,
                  decoded.base64EncodedString() == key else { return nil }
            return decoded
        case "hex":
            guard key.count.isMultiple(of: 2), !key.isEmpty else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(key.count / 2)
            var index = key.startIndex
            while index < key.endIndex {
                let next = key.index(index, offsetBy: 2)
                guard let byte = UInt8(key[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return Data(bytes)
        case "utf8":
            return Data(key.utf8)
        default:
            return nil
        }
    }

    private func normalizeStrictUnpaddedBase32(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        var normalized: [UInt8] = []
        normalized.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 65...90, 50...55: normalized.append(byte)
            case 97...122: normalized.append(byte - 32)
            default: return nil
            }
        }

        let remainder = normalized.count % 8
        let unusedBits: Int
        switch remainder {
        case 0: return String(bytes: normalized, encoding: .ascii)
        case 2: unusedBits = 2
        case 4: unusedBits = 4
        case 5: unusedBits = 1
        case 7: unusedBits = 3
        default: return nil
        }
        guard let last = normalized.last else { return nil }
        let lastValue = last >= 65 ? Int(last - 65) : Int(last - 50 + 26)
        guard lastValue & ((1 << unusedBits) - 1) == 0 else { return nil }
        return String(bytes: normalized, encoding: .ascii)
    }

    private func parseTOTPFromURI(_ uri: String, sessionKey: SymmetricKey) -> TOTPConfig? {
        guard let components = URLComponents(string: uri) else { return nil }
        let params = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name.lowercased(), $0) }
            }
        )

        guard let secret = params["secret"] else { return nil }
        let encryptedSecret = (try? EncryptedValue.encrypt(secret, using: sessionKey)) ?? .empty
        let period = Int(params["period"] ?? "30") ?? 30
        let digits = Int(params["digits"] ?? "6") ?? 6
        let algorithm = TOTPAlgorithm(rawValue: (params["algorithm"] ?? "SHA1").uppercased()) ?? .sha1

        return TOTPConfig(secret: encryptedSecret, period: period, digits: digits, algorithm: algorithm)
    }
}
