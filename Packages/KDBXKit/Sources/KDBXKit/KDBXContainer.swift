import Foundation
import CryptoKit

/// The KDBX container: outer header, key derivation, authenticated blocks,
/// outer encryption, compression, and the KDBX 4 inner header. Reading yields
/// the header and the database XML; the XML's meaning is the caller's.
public enum KDBXContainer {
    // MARK: - Constants

    public static let kdbxSignature1: UInt32 = 0x9AA2D903
    public static let kdbxSignature2: UInt32 = 0xB54BFB67
    public static let versionKDBX3: UInt16 = 3
    public static let versionKDBX4: UInt16 = 4

    // Cipher UUIDs (16 bytes)
    public static let aesCipherUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                                            0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
    public static let chachaCipherUUID = Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5,
                                               0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])
    public static let twofishCipherUUID = Data([0xAD, 0x68, 0xF2, 0x9F, 0x57, 0x6F, 0x4B, 0xB9,
                                                0xA3, 0x6A, 0xD4, 0x7A, 0xF9, 0x65, 0x34, 0x6C])

    // KDF UUIDs
    public static let argon2dUUID = Data([0xEF, 0x63, 0x6D, 0xDF, 0x8C, 0x29, 0x44, 0x4B,
                                          0x91, 0xF7, 0xA9, 0xA4, 0x03, 0xE3, 0x0A, 0x0C])
    public static let argon2idUUID = Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73,
                                           0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
    public static let aesKDFUUID = Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60,
                                         0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])
    public static let aesKDFMaxRounds: UInt64 = 100_000_000

    // Inner random stream IDs
    public static let innerStreamNone: UInt32 = 0
    public static let innerStreamArcFourVariant: UInt32 = 1
    public static let innerStreamSalsa20: UInt32 = 2
    public static let innerStreamChaCha20: UInt32 = 3

    // MARK: - Header Fields

    public enum HeaderField: UInt8, Sendable {
        case endOfHeader = 0
        case cipherID = 2
        case compressionFlags = 3
        case masterSeed = 4
        case encryptionIV = 7
        case kdfParameters = 11
    }

    public enum InnerHeaderField: UInt8, Sendable {
        case endOfHeader = 0
        case innerRandomStreamID = 1
        case innerRandomStreamKey = 2
        case binary = 3
    }

    public enum LegacyHeaderField: UInt8, Sendable {
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

    public enum FileVersion: Equatable, Sendable {
        case kdbx3_1
        case kdbx4(minor: UInt16)

        public var majorVersion: UInt16 {
            switch self {
            case .kdbx3_1:
                versionKDBX3
            case .kdbx4:
                versionKDBX4
            }
        }

        public var minorVersion: UInt16 {
            switch self {
            case .kdbx3_1:
                1
            case .kdbx4(let minor):
                minor
            }
        }

        public var requiresReadOnlyMode: Bool {
            switch self {
            case .kdbx3_1:
                true
            case .kdbx4:
                false
            }
        }
    }

    // MARK: - Parsed Header

    public struct UnknownHeaderField: Equatable, Sendable {
        public let id: UInt8
        public let data: Data

        public init(id: UInt8, data: Data) {
            self.id = id
            self.data = data
        }
    }

    /// The outer and inner header of an opened file. A KDBX 3.1 header is
    /// mapped onto the same shape (its protected stream key becomes
    /// `innerStreamKey`), so callers decode protected values the same way.
    public struct Header: @unchecked Sendable {
        public var formatVersion: FileVersion
        public var cipherID: Data
        public var compressionFlags: UInt32
        public var masterSeed: Data
        public var encryptionIV: Data
        public var kdfParameters: [String: Any]
        public var unknownOuterHeaderFields: [UnknownHeaderField]
        /// Raw outer header bytes, as covered by the header SHA-256 and HMAC.
        public var headerData: Data
        public var innerStreamID: UInt32
        public var innerStreamKey: Data
        /// The KDBX 4 binary pool, each item with its leading flags byte.
        public var innerHeaderBinaryFields: [Data]
        public var unknownInnerHeaderFields: [UnknownHeaderField]

        public init(
            formatVersion: FileVersion = .kdbx4(minor: 0),
            cipherID: Data = Data(),
            compressionFlags: UInt32 = 0,
            masterSeed: Data = Data(),
            encryptionIV: Data = Data(),
            kdfParameters: [String: Any] = [:],
            unknownOuterHeaderFields: [UnknownHeaderField] = [],
            headerData: Data = Data(),
            innerStreamID: UInt32 = 0,
            innerStreamKey: Data = Data(),
            innerHeaderBinaryFields: [Data] = [],
            unknownInnerHeaderFields: [UnknownHeaderField] = []
        ) {
            self.formatVersion = formatVersion
            self.cipherID = cipherID
            self.compressionFlags = compressionFlags
            self.masterSeed = masterSeed
            self.encryptionIV = encryptionIV
            self.kdfParameters = kdfParameters
            self.unknownOuterHeaderFields = unknownOuterHeaderFields
            self.headerData = headerData
            self.innerStreamID = innerStreamID
            self.innerStreamKey = innerStreamKey
            self.innerHeaderBinaryFields = innerHeaderBinaryFields
            self.unknownInnerHeaderFields = unknownInnerHeaderFields
        }
    }

    /// A decrypted file: its header and the (decompressed) database XML, with
    /// protected values still under the inner random stream.
    public struct Payload: @unchecked Sendable {
        public var header: Header
        public var xml: Data

        public init(header: Header, xml: Data) {
            self.header = header
            self.xml = xml
        }
    }

    // MARK: - Errors

    public enum ParseError: Error, Equatable, Sendable {
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
        case kdfResourceLimitExceeded(iterations: UInt64, memoryBytes: UInt64, parallelism: UInt32)
    }

    // MARK: - Constant-Time Comparison

    /// Compare two Data values in constant time to prevent timing side-channels on HMAC/hash checks.
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

    // MARK: - Reading

    /// Decrypts a KDBX 3.1 or 4.x file with its composite key.
    public static func read(
        data: Data,
        compositeKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Payload {
        switch try parseFileVersion(from: data) {
        case .kdbx3_1:
            return try readKDBX3(data: data, compositeKey: compositeKey)
        case .kdbx4:
            return try readKDBX4(data: data) { kdfParameters in
                try deriveKey(compositeKey: compositeKey, kdfParams: kdfParameters, kdfPolicy: kdfPolicy)
            }
        }
    }

    public static func parseFileVersion(from data: Data) throws -> FileVersion {
        var reader = DataReader(data: data)
        return try parseVersion(from: &reader)
    }

    /// Decrypts a KDBX 4 file with the KDF output supplied by `transformedKey`,
    /// which receives the header's KDF parameters. A key that does not belong
    /// to the file fails the header HMAC (`CryptoError.hmacMismatch`).
    public static func readKDBX4(
        data: Data,
        transformedKey provideTransformedKey: (_ kdfParameters: [String: Any]) throws -> Data
    ) throws -> Payload {
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

        let storedHeaderSHA = try reader.readBytes(32)
        let storedHeaderHMAC = try reader.readBytes(32)

        let computedHeaderSHA = KDBXCrypto.sha256(headerBytes)
        guard constantTimeEqual(storedHeaderSHA, computedHeaderSHA) else {
            throw ParseError.invalidSignature
        }

        let decryptedPayload: Data
        do {
            var transformedKey = try provideTransformedKey(header.kdfParameters)
            defer { SecureWipe.wipe(&transformedKey) }

            // Master key = SHA256(masterSeed + transformedKey)
            var preKey = Data(capacity: 64)
            defer { SecureWipe.wipe(&preKey) }
            preKey.append(header.masterSeed)
            preKey.append(transformedKey)
            var masterKey = KDBXCrypto.sha256(preKey)
            defer { SecureWipe.wipe(&masterKey) }

            var hmacPreKey = Data(capacity: 65)
            defer { SecureWipe.wipe(&hmacPreKey) }
            hmacPreKey.append(header.masterSeed)
            hmacPreKey.append(transformedKey)
            hmacPreKey.append(Data([0x01]))
            var hmacBaseKey = KDBXCrypto.sha512(hmacPreKey)
            defer { SecureWipe.wipe(&hmacBaseKey) }

            var headerHMACKey = computeBlockHMACKey(blockIndex: UInt64.max, baseKey: hmacBaseKey)
            defer { SecureWipe.wipe(&headerHMACKey) }
            let computedHeaderHMAC = KDBXCrypto.hmacSHA256(key: headerHMACKey, data: headerBytes)
            guard constantTimeEqual(storedHeaderHMAC, computedHeaderHMAC) else {
                throw KDBXCrypto.CryptoError.hmacMismatch
            }

            let encryptedPayload = try readHMACBlocks(reader: &reader, baseKey: hmacBaseKey)

            let cipher = try KDBXOuterCipher.require(uuid: header.cipherID)
            decryptedPayload = try cipher.decrypt(
                data: encryptedPayload,
                key: masterKey,
                iv: header.encryptionIV
            )
        }

        var payloadForInnerHeader = decryptedPayload
        var payloadWasPreDecompressed = false
        if header.compressionFlags == 1, let decompressedPayload = try? KDBXCrypto.gunzip(decryptedPayload) {
            payloadForInnerHeader = decompressedPayload
            payloadWasPreDecompressed = true
        }

        var innerReader = DataReader(data: payloadForInnerHeader)
        let innerHeader = try parseInnerHeader(&innerReader)
        header.innerStreamID = innerHeader.streamID
        header.innerStreamKey = innerHeader.streamKey
        header.innerHeaderBinaryFields = innerHeader.binaryFields
        header.unknownInnerHeaderFields = innerHeader.unknownFields

        // Some producers omit the inner header and write payload directly.
        // If we consumed the whole payload without discovering header fields,
        // rewind and treat decrypted bytes as XML/compressed XML.
        let missingInnerHeader = innerReader.offset == payloadForInnerHeader.count &&
            innerHeader.streamID == 0 &&
            innerHeader.streamKey.isEmpty
        if missingInnerHeader {
            innerReader.offset = 0
            header.unknownInnerHeaderFields = []
        }

        let innerPayload = payloadForInnerHeader.subdata(in: innerReader.offset..<payloadForInnerHeader.count)

        let xmlData: Data
        if payloadWasPreDecompressed {
            xmlData = innerPayload
        } else if header.compressionFlags == 1 {
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

        return Payload(header: header, xml: xmlData)
    }

    public static func parseVersion(from reader: inout DataReader) throws -> FileVersion {
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

    /// Reads the KDBX 4 outer header fields that follow the version.
    public static func parseHeader(_ reader: inout DataReader) throws -> Header {
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

    public static func parseInnerHeader(
        _ reader: inout DataReader
    ) throws -> (streamID: UInt32, streamKey: Data, binaryFields: [Data], unknownFields: [UnknownHeaderField]) {
        var streamID: UInt32 = 0
        var streamKey = Data()
        var binaryFields: [Data] = []
        var unknownFields: [UnknownHeaderField] = []

        while reader.hasMore {
            let fieldID = try reader.readUInt8()
            let fieldSize = Int(try reader.readUInt32())

            guard let field = InnerHeaderField(rawValue: fieldID) else {
                unknownFields.append(
                    UnknownHeaderField(id: fieldID, data: try reader.readBytes(fieldSize))
                )
                continue
            }

            switch field {
            case .endOfHeader:
                try reader.skip(fieldSize)
                return (streamID, streamKey, binaryFields, unknownFields)
            case .innerRandomStreamID:
                streamID = try reader.readUInt32From(fieldSize)
            case .innerRandomStreamKey:
                streamKey = try reader.readBytes(fieldSize)
            case .binary:
                binaryFields.append(try reader.readBytes(fieldSize))
            }
        }

        return (streamID, streamKey, binaryFields, unknownFields)
    }

    // MARK: - Variant Map (KDF Parameters)

    static func parseVariantMap(_ data: Data) throws -> [String: Any] {
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

    public static func deriveKey(compositeKey: SymmetricKey, kdfParams: [String: Any], kdfPolicy: KDFExecutionPolicy) throws -> Data {
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
        let argon2Version = (kdfParams["V"] as? UInt32) ?? 0x13

        // Format validation (RFC 9106) — these params are attacker-controlled (from file header)
        guard iterations >= 1 else {
            throw ParseError.kdfParameterOutOfRange("iterations \(iterations) must be >= 1")
        }
        guard parallelism >= 1, parallelism <= 0xFF_FFFF else {
            throw ParseError.kdfParameterOutOfRange("parallelism \(parallelism) not in 1...16777215")
        }
        let memoryKiB = memory / 1024
        guard memory >= 8192, memoryKiB >= 8 * UInt64(parallelism) else {
            throw ParseError.kdfParameterOutOfRange("memory \(memory) bytes below Argon2 minimum for \(parallelism) lanes")
        }
        guard let version = Argon2.Version(rawValue: argon2Version) else {
            throw ParseError.kdfParameterOutOfRange("unsupported Argon2 version 0x\(String(argon2Version, radix: 16))")
        }

        // Runs before the UInt32 conversions so absurd values get the actionable
        // resource-limit error, not a generic parse failure.
        try kdfPolicy.validate(iterations: iterations, memoryBytes: memory, parallelism: parallelism)

        // Unreachable under any policy whose budgets fit UInt32 KiB/iterations;
        // kept as defense for synthetic policies.
        guard let iterationsU32 = UInt32(exactly: iterations) else {
            throw ParseError.kdfParameterOutOfRange("iterations \(iterations) overflows UInt32")
        }
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
            version: version,
            variant: variant
        )
    }

    // MARK: - HMAC Block Reading

    public static func readHMACBlocks(reader: inout DataReader, baseKey: Data) throws -> Data {
        var result = Data()
        var blockIndex: UInt64 = 0

        while true {
            let storedHMAC = try reader.readBytes(32)
            let blockSizeRaw = try reader.readInt32()

            guard blockSizeRaw >= 0 else { throw ParseError.truncatedFile }

            if blockSizeRaw == 0 {
                // Final block — verify HMAC of empty block
                var hmacKey = computeBlockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
                defer { SecureWipe.wipe(&hmacKey) }
                var msg = Data()
                msg.append(withUInt64: blockIndex)
                msg.append(withInt32: 0)
                let computed = KDBXCrypto.hmacSHA256(key: hmacKey, data: msg)
                guard constantTimeEqual(storedHMAC, computed) else { throw ParseError.invalidBlockHMAC }
                break
            }

            let blockData = try reader.readBytes(Int(blockSizeRaw))

            var hmacKey = computeBlockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
            defer { SecureWipe.wipe(&hmacKey) }
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

    public static func computeBlockHMACKey(blockIndex: UInt64, baseKey: Data) -> Data {
        var keyMaterial = Data(capacity: 8 + baseKey.count)
        defer { SecureWipe.wipe(&keyMaterial) }
        keyMaterial.append(withUInt64: blockIndex)
        keyMaterial.append(baseKey)
        return KDBXCrypto.sha512(keyMaterial)
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

// MARK: - Data Reader

/// Little-endian cursor over the binary header and block structures.
public struct DataReader {
    public let data: Data
    public var offset: Int = 0

    public init(data: Data) {
        self.data = data
    }

    public var hasMore: Bool { offset < data.count }

    public mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw KDBXContainer.ParseError.truncatedFile }
        let val = data[offset]
        offset += 1
        return val
    }

    public mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(2)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
    }

    public mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    public mutating func readInt32() throws -> Int32 {
        let bytes = try readBytes(4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
    }

    public mutating func readUInt32From(_ size: Int) throws -> UInt32 {
        let bytes = try readBytes(size)
        guard bytes.count >= 4 else { throw KDBXContainer.ParseError.truncatedFile }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    public mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw KDBXContainer.ParseError.truncatedFile
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    public mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw KDBXContainer.ParseError.truncatedFile
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
