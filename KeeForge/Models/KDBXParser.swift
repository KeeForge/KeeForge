import Foundation
import CryptoKit

/// Full KDBX 4.x parser — reads header, derives key, decrypts, decompresses, parses XML
enum KDBXParser {
    // MARK: - Constants

    static let kdbxSignature1: UInt32 = 0x9AA2D903
    static let kdbxSignature2: UInt32 = 0xB54BFB67
    static let versionKDBX4: UInt16 = 4

    // Cipher UUIDs (16 bytes)
    static let aesCipherUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                                     0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
    static let chachaCipherUUID = Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5,
                                        0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])

    // KDF UUIDs
    static let argon2dUUID = Data([0xEF, 0x63, 0x6D, 0xDF, 0x8C, 0x29, 0x44, 0x4B,
                                   0x91, 0xF7, 0xA9, 0xA4, 0x03, 0xE3, 0x0A, 0x0C])
    static let argon2idUUID = Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73,
                                    0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])

    // Inner random stream IDs
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

    // MARK: - Parsed Header

    struct Header {
        var cipherID = Data()
        var compressionFlags: UInt32 = 0
        var masterSeed = Data()
        var encryptionIV = Data()
        var kdfParameters: [String: Any] = [:]
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
        case innerHeaderInvalid
        case malformedVariantMap
        case kdfParameterOutOfRange(String)

        var errorDescription: String? {
            switch self {
            case .invalidSignature: "Not a valid KDBX file"
            case .unsupportedVersion(let v): "Unsupported KDBX version: \(v)"
            case .truncatedFile: "File is truncated"
            case .headerFieldMissing(let f): "Missing header field: \(f)"
            case .xmlParsingFailed: "Failed to parse database XML"
            case .invalidBlockHMAC: "Block HMAC invalid — wrong password or corrupted file"
            case .innerHeaderInvalid: "Invalid inner header"
            case .malformedVariantMap: "Malformed variant map in header"
            case .kdfParameterOutOfRange(let p): "KDF parameter out of range: \(p)"
            }
        }
    }

    // MARK: - Constant-Time Comparison

    /// Compare two Data values in constant time to prevent timing side-channels on HMAC/hash checks.
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
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
        var reader = DataReader(data: data)

        // 1. Verify signatures
        let sig1 = try reader.readUInt32()
        let sig2 = try reader.readUInt32()
        guard sig1 == kdbxSignature1, sig2 == kdbxSignature2 else {
            throw ParseError.invalidSignature
        }

        // 2. Version
        let _ = try reader.readUInt16()
        let versionMajor = try reader.readUInt16()
        guard versionMajor == versionKDBX4 else {
            throw ParseError.unsupportedVersion(versionMajor)
        }

        // 3. Parse outer header
        let headerStart = 0
        var header = try parseHeader(&reader)
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
        let decryptedPayload: Data
        if header.cipherID == aesCipherUUID {
            decryptedPayload = try KDBXCrypto.decryptAES256CBC(
                data: encryptedPayload, key: masterKey, iv: header.encryptionIV
            )
        } else if header.cipherID == chachaCipherUUID {
            decryptedPayload = try KDBXCrypto.decryptChaCha20Poly1305(
                data: encryptedPayload, key: masterKey, nonce: header.encryptionIV
            )
        } else {
            throw KDBXCrypto.CryptoError.unsupportedCipher(header.cipherID.hexString)
        }

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

    // MARK: - Header Parsing

    static func parseHeader(_ reader: inout DataReader) throws -> Header {
        var header = Header()

        while reader.hasMore {
            let fieldID = try reader.readUInt8()
            let fieldSize = Int(try reader.readUInt32())

            guard let field = HeaderField(rawValue: fieldID) else {
                try reader.skip(fieldSize)
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
            throw KDBXCrypto.CryptoError.unsupportedKDF("missing UUID")
        }

        let variant: Argon2Variant
        if uuidData == argon2dUUID {
            variant = .d
        } else if uuidData == argon2idUUID {
            variant = .id
        } else {
            throw KDBXCrypto.CryptoError.unsupportedKDF(uuidData.hexString)
        }

        guard let salt = kdfParams["S"] as? Data else {
            throw KDBXCrypto.CryptoError.unsupportedKDF("missing salt")
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

    private static func parseXML(
        xmlData: Data,
        innerStreamKey: Data,
        innerStreamID: UInt32,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
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
        var unknownXML = OpaqueXMLNodes.empty
        var knownChildCount = 0

        func build() -> KPMeta {
            KPMeta(
                recycleBinUUID: recycleBinUUID,
                hasRecycleBinUUIDElement: hasRecycleBinUUIDElement,
                unknownXML: unknownXML
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

    private let data: Data
    private let innerStreamKey: Data
    private let innerStreamID: UInt32
    private let sessionKey: SymmetricKey

    private var groupStack: [GroupBuilder] = []
    private var currentMeta = MetaBuilder()
    private var currentEntry: EntryBuilder?
    private var currentKey = ""
    private var currentValue = ""
    private var currentText = ""
    private var isProtected = false
    private var currentStringWasProtected = false
    private var inValue = false
    private var inKey = false
    private var historyDepth = 0
    private var inMeta = false
    private var captureStack: [XMLCaptureElement] = []

    // Inner stream cipher state for decrypting protected values
    private var chachaCounter: UInt32 = 0
    private var keystreamBlock = Data()
    private var keystreamBlockOffset = 0
    private lazy var streamCipherKey: Data = {
        KDBXCrypto.sha512(innerStreamKey)
    }()
    private lazy var innerChaChaKey: Data = {
        Data(streamCipherKey.prefix(32))
    }()
    private lazy var innerChaChaNonce: Data = {
        Data(streamCipherKey[32..<44])
    }()

    private var rootEntries: [KPEntry] = []
    private var rootGroups: [KPGroup] = []
    private var rootUnknownXML = OpaqueXMLNodes.empty
    private var rootKnownChildCount = 0
    private var meta = KPMeta()
    private static let syntheticRootUUID = nullUUID

    init(data: Data, innerStreamKey: Data, innerStreamID: UInt32, sessionKey: SymmetricKey) {
        self.data = data
        self.innerStreamKey = innerStreamKey
        self.innerStreamID = innerStreamID
        self.sessionKey = sessionKey
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
        return (root, meta)
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

        case "Group":
            groupStack.append(GroupBuilder())

        case "History":
            historyDepth += 1

        case "Entry":
            // Ignore entries nested under <History>.
            if !isInsideHistory() {
                currentEntry = EntryBuilder()
            }

        case "String":
            currentKey = ""
            currentValue = ""
            isProtected = false
            currentStringWasProtected = false

        case "Key":
            inKey = true

        case "Value":
            inValue = true
            currentStringWasProtected = attributes["Protected"]?.lowercased() == "true"
            isProtected = currentStringWasProtected

        case "Times":
            if !isInsideHistory(), currentEntry != nil {
                currentEntry?.timesKnownChildCount = 0
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

        case "Group":
            let group = groupStack.removeLast().build()
            if let index = groupStack.indices.last {
                groupStack[index].groups.append(group)
            } else {
                rootGroups.append(group)
            }

        case "History":
            historyDepth = max(0, historyDepth - 1)

        case "Entry":
            if !isInsideHistory(), let builder = currentEntry {
                let entry = builder.build(sessionKey: sessionKey)
                if let index = groupStack.indices.last {
                    groupStack[index].entries.append(entry)
                } else {
                    rootEntries.append(entry)
                }
                currentEntry = nil
            }

        case "Name":
            if !inMeta, currentEntry == nil, let index = groupStack.indices.last {
                groupStack[index].name = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

        case "IconID":
            let val = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if !isInsideHistory(), currentEntry != nil {
                currentEntry?.iconID = val
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
                var val = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if isProtected, let decoded = Data(base64Encoded: val) {
                    val = decryptProtectedValue(decoded)
                }
                currentValue = val
                inValue = false
            }

        case "String":
            if !isInsideHistory(), let entry = currentEntry {
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
                    if currentKey.hasPrefix("TimeOtp-") || currentKey == "TOTP Settings" || currentKey == "TOTP Seed" {
                        entry.customFields[currentKey] = currentValue
                    } else if !currentKey.isEmpty {
                        entry.customFields[currentKey] = currentValue
                    }
                }
            }

        case "Times":
            break // handled by sub-elements

        case "CreationTime":
            let date = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            if !isInsideHistory(), currentEntry != nil {
                currentEntry?.creationTime = date
            } else if let index = groupStack.indices.last {
                groupStack[index].creationTime = date
            }

        case "LastModificationTime":
            let date = parseKPDate(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            if !isInsideHistory(), currentEntry != nil {
                currentEntry?.lastModificationTime = date
            } else if let index = groupStack.indices.last {
                groupStack[index].lastModificationTime = date
            }

        case "Tags":
            if !isInsideHistory(), let entry = currentEntry {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    entry.tags = trimmed.components(separatedBy: CharacterSet([",", ";"])).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty }
                }
            }

        case "UUID":
            if !isInsideHistory(), let entry = currentEntry, !inMeta {
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
        guard innerStreamID == KDBXParser.innerStreamChaCha20 else {
            // Salsa20 or other — not supported in v1
            return String(data: encrypted, encoding: .utf8) ?? ""
        }

        guard innerChaChaKey.count == 32, innerChaChaNonce.count == 12 else {
            return String(data: encrypted, encoding: .utf8) ?? ""
        }

        // KDBX4 protected values consume one continuous ChaCha20 stream.
        var decrypted = Data()
        decrypted.reserveCapacity(encrypted.count)

        for byte in encrypted {
            decrypted.append(byte ^ nextKeystreamByte())
        }

        return String(data: decrypted, encoding: .utf8) ?? ""
    }

    private func nextKeystreamByte() -> UInt8 {
        if keystreamBlockOffset >= keystreamBlock.count {
            keystreamBlock = makeChaCha20Block(counter: chachaCounter)
            keystreamBlockOffset = 0
            chachaCounter &+= 1
        }

        let byte = keystreamBlock[keystreamBlockOffset]
        keystreamBlockOffset += 1
        return byte
    }

    private func makeChaCha20Block(counter: UInt32) -> Data {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x61707865
        state[1] = 0x3320646e
        state[2] = 0x79622d32
        state[3] = 0x6b206574

        innerChaChaKey.withUnsafeBytes { ptr in
            for i in 0..<8 {
                state[4 + i] = ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
            }
        }

        state[12] = counter
        innerChaChaNonce.withUnsafeBytes { ptr in
            for i in 0..<3 {
                state[13 + i] = ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
            }
        }

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

        for i in 0..<16 {
            working[i] = working[i] &+ state[i]
        }

        var block = Data(capacity: 64)
        for word in working {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { bytes in
                block.append(contentsOf: bytes)
            }
        }
        return block
    }

    private func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 16) | (s[d] >> 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 12) | (s[b] >> 20)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 8) | (s[d] >> 24)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 7) | (s[b] >> 25)
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
            if elementName == "Entry" || elementName == "Group" {
                rootKnownChildCount += 1
            } else {
                rootUnknownXML.append(xml: xml, insertionIndex: rootKnownChildCount)
            }

        case "Meta":
            if elementName == "RecycleBinUUID" {
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
            guard !isInsideHistory(), let entry = currentEntry else { return }
            switch elementName {
            case "UUID", "IconID", "Tags", "Times", "String":
                entry.knownChildCount += 1
            default:
                entry.unknownXML.append(xml: xml, insertionIndex: entry.knownChildCount)
            }

        case "Times":
            switch grandparentName {
            case "Entry":
                guard !isInsideHistory(), let entry = currentEntry else { return }
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

    private func parseKPDate(_ string: String) -> Date? {
        // KDBX4 can use base64-encoded binary date or ISO 8601
        if string.contains("-") || string.contains("T") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        // Base64 binary timestamp (seconds since 0001-01-01)
        if let data = Data(base64Encoded: string), data.count == 8 {
            let seconds = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).littleEndian }
            guard let kpEpoch = DateComponents(
                calendar: .init(identifier: .gregorian),
                year: 1,
                month: 1,
                day: 1
            ).date else {
                return nil
            }
            return kpEpoch.addingTimeInterval(TimeInterval(seconds))
        }
        return nil
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
    var tags: [String] = []
    var customFields: [String: String] = [:]
    var protectedStringKeys: Set<String> = []
    var otpURL: String?
    var creationTime: Date?
    var lastModificationTime: Date?
    var unknownXML = OpaqueXMLNodes.empty
    var knownChildCount = 0
    var timesKnownChildCount = 0

    func build(sessionKey: SymmetricKey) -> KPEntry {
        let encryptedPassword = (try? EncryptedValue.encrypt(password, using: sessionKey)) ?? .empty
        let totpConfig = buildTOTPConfig(sessionKey: sessionKey)
        return KPEntry(
            id: uuid ?? UUID(),
            title: title,
            username: username,
            password: encryptedPassword,
            url: url,
            notes: notes,
            iconID: iconID,
            tags: tags,
            customFields: customFields.filter { !$0.key.hasPrefix("TimeOtp-") && $0.key != "TOTP Settings" && $0.key != "TOTP Seed" },
            totpConfig: totpConfig,
            creationTime: creationTime,
            lastModificationTime: lastModificationTime,
            unknownXML: unknownXML,
            protectedStringKeys: protectedStringKeys
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

        return nil
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
