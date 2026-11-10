import CryptoKit
import Foundation

/// The KDBX container: outer header, key derivation, authenticated blocks,
/// outer encryption, compression, and the KDBX 4 inner header. Reading yields
/// the header and the database XML; the XML's meaning is the caller's.
///
/// KDBX 3.1 files are read through the same API. Their header is mapped onto
/// the KDBX 4 shape: the transform seed and rounds become AES-KDF parameters,
/// and the protected stream ID and key become the inner stream fields.
public enum KDBXContainer {
    public enum FileVersion: Hashable, Sendable {
        case kdbx3_1
        case kdbx4(minor: UInt16)

        public var majorVersion: UInt16 {
            switch self {
            case .kdbx3_1: 3
            case .kdbx4: 4
            }
        }

        public var minorVersion: UInt16 {
            switch self {
            case .kdbx3_1: 1
            case .kdbx4(let minor): minor
            }
        }

        /// This library writes KDBX 4 only.
        public var requiresReadOnlyMode: Bool {
            self == .kdbx3_1
        }
    }

    public enum Compression: UInt32, Sendable, CaseIterable {
        case none = 0
        case gzip = 1
    }

    /// The largest decompressed payload a read accepts. A write refuses to
    /// compress anything larger, or it would produce a file it cannot open again.
    public static let maxDecompressedPayloadSize = 256 * 1024 * 1024

    public struct UnknownHeaderField: Hashable, Sendable {
        public let id: UInt8
        public let data: Data

        public init(id: UInt8, data: Data) {
            self.id = id
            self.data = data
        }
    }

    /// The outer and inner header of a file. Raw values (cipher UUID,
    /// compression flags, stream ID) are kept as stored, so a value this
    /// library does not know survives and can be reported.
    public struct Header: Hashable, Sendable {
        public var formatVersion: FileVersion
        public var cipherID: Data
        public var compressionFlags: UInt32
        public var masterSeed: Data
        public var encryptionIV: Data
        public var kdfParameters: KDBXVariantMap
        public var unknownOuterHeaderFields: [UnknownHeaderField]
        /// Raw outer header bytes, as covered by the header hash and HMAC.
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
            kdfParameters: KDBXVariantMap = [:],
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

        /// nil for a cipher this library does not support.
        public var cipher: KDBXOuterCipher? { KDBXOuterCipher(uuid: cipherID) }
        /// nil for compression flags this library does not support.
        public var compression: Compression? { Compression(rawValue: compressionFlags) }
        /// nil when the KDF parameters name no KDF or one this library does not know.
        public var keyDerivation: KDBXKeyDerivation? { KDBXKeyDerivation(parameters: kdfParameters) }
    }

    /// A decrypted file: its header and the decompressed database XML, with
    /// protected values still under the inner random stream.
    public struct Payload: Hashable, Sendable {
        public var header: Header
        public var xml: Data

        public init(header: Header, xml: Data) {
            self.header = header
            self.xml = xml
        }
    }

    public enum ParseError: Error, Hashable, Sendable {
        /// Not a KDBX file.
        case invalidSignature
        /// A KDBX 4 outer header whose stored SHA-256 does not match: a damaged file.
        case headerHashMismatch
        case unsupportedVersion(UInt16)
        case truncatedFile
        /// A KDBX 4 payload block failed its HMAC: wrong key or a damaged file.
        case invalidBlockHMAC
        /// A KDBX 3.1 payload block failed its SHA-256: a damaged file.
        case invalidLegacyBlockHash
        /// KDBX 3.1's check that the key decrypts the payload failed.
        case invalidStreamStartBytes
        case unsupportedProtectedFieldStream(UInt32)
        case malformedVariantMap
        /// The payload decompresses to more than `maxDecompressedPayloadSize`.
        case decompressedPayloadTooLarge
        case kdfParameterOutOfRange(String)
        case kdfResourceLimitExceeded(iterations: UInt64, memoryBytes: UInt64, parallelism: UInt32)
    }

    // MARK: - Reading

    /// The file's format version, from its first 12 bytes.
    public static func parseFileVersion(from data: Data) throws -> FileVersion {
        var reader = DataReader(data: Data(data.prefix(12)))
        return try parseVersion(from: &reader)
    }

    /// The plaintext header, read without credentials. `data` may be a prefix
    /// of the file as long as it covers the header. KDBX 4 inner header fields
    /// are encrypted, so they are empty here.
    public static func readHeader(from data: Data) throws -> Header {
        let data = zeroBased(data)
        var reader = DataReader(data: data)
        switch try parseVersion(from: &reader) {
        case .kdbx3_1:
            return try LegacyHeader(reading: &reader).header
        case .kdbx4(let minor):
            var header = try parseOuterHeader(&reader)
            header.formatVersion = .kdbx4(minor: minor)
            header.headerData = data.prefix(reader.offset)
            return header
        }
    }

    /// Decrypts a file with its composite key, running the KDF under `kdfPolicy`.
    public static func read(
        data: Data,
        compositeKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Payload {
        try read(data: data) { kdfParameters in
            try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: kdfParameters, policy: kdfPolicy)
        }
    }

    /// Decrypts a file with the KDF output supplied by `transformedKey`, which
    /// receives the header's KDF parameters. On KDBX 4, a key that does not
    /// belong to the file fails the header HMAC (`CryptoError.hmacMismatch`);
    /// on KDBX 3.1, the stream start bytes (`ParseError.invalidStreamStartBytes`).
    public static func read(
        data: Data,
        transformedKey provideTransformedKey: (_ kdfParameters: KDBXVariantMap) throws -> Data
    ) throws -> Payload {
        let data = zeroBased(data)
        var reader = DataReader(data: data)
        switch try parseVersion(from: &reader) {
        case .kdbx3_1:
            return try readKDBX3(data: data, reader: &reader, transformedKey: provideTransformedKey)
        case .kdbx4(let minor):
            return try readKDBX4(data: data, minor: minor, reader: &reader, transformedKey: provideTransformedKey)
        }
    }

    private static func readKDBX4(
        data: Data,
        minor: UInt16,
        reader: inout DataReader,
        transformedKey provideTransformedKey: (KDBXVariantMap) throws -> Data
    ) throws -> Payload {
        var header = try parseOuterHeader(&reader)
        header.formatVersion = .kdbx4(minor: minor)
        let headerBytes = data.prefix(reader.offset)
        header.headerData = headerBytes

        let storedHeaderSHA = try reader.readBytes(32)
        let storedHeaderHMAC = try reader.readBytes(32)
        guard constantTimeEqual(storedHeaderSHA, KDBXCrypto.sha256(headerBytes)) else {
            throw ParseError.headerHashMismatch
        }

        var keys = try MasterKeys(masterSeed: header.masterSeed, transformedKey: provideTransformedKey(header.kdfParameters))
        defer { keys.wipe() }

        guard constantTimeEqual(storedHeaderHMAC, keys.headerHMAC(for: headerBytes)) else {
            throw KDBXCrypto.CryptoError.hmacMismatch
        }

        let encryptedPayload = try readHMACBlocks(reader: &reader, baseKey: keys.hmacBaseKey)
        let cipher = try KDBXOuterCipher.require(uuid: header.cipherID)
        let decrypted = try cipher.decrypt(data: encryptedPayload, key: keys.masterKey, iv: header.encryptionIV)

        // Standard KDBX 4 compresses the inner header and XML together. Some
        // producers leave the inner header uncompressed and compress only the
        // XML, or write plain XML despite the flag; both still read.
        let isCompressed = header.compressionFlags == Compression.gzip.rawValue
        let wholePayload = isCompressed ? try decompressIfPossible(decrypted) : nil
        let payload = wholePayload ?? decrypted

        var innerReader = DataReader(data: payload)
        try parseInnerHeader(&innerReader, into: &header)
        var xml = payload.subdata(in: innerReader.offset..<payload.count)

        if isCompressed, wholePayload == nil {
            if let decompressedXML = try decompressIfPossible(xml) {
                xml = decompressedXML
            } else if !looksLikeXML(xml) {
                throw KDBXCrypto.CryptoError.decompressionFailed
            }
        }
        return Payload(header: header, xml: xml)
    }

    /// nil when `data` is not compressed. Exceeding the size limit still throws,
    /// so an oversized payload is not mistaken for an uncompressed one.
    private static func decompressIfPossible(_ data: Data) throws -> Data? {
        do {
            return try Gzip.decompress(data, maxOutputSize: maxDecompressedPayloadSize)
        } catch ParseError.decompressedPayloadTooLarge {
            throw ParseError.decompressedPayloadTooLarge
        } catch {
            return nil
        }
    }

    /// Internal offsets assume a zero-based buffer; a slice is copied once.
    private static func zeroBased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }

    // MARK: - Header Parsing

    static let signature1: UInt32 = 0x9AA2D903
    static let signature2: UInt32 = 0xB54BFB67

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

    static func parseVersion(from reader: inout DataReader) throws -> FileVersion {
        guard try reader.readUInt32() == signature1, try reader.readUInt32() == signature2 else {
            throw ParseError.invalidSignature
        }

        let minor = try reader.readUInt16()
        let major = try reader.readUInt16()
        switch major {
        case 3 where minor == 1:
            return .kdbx3_1
        case 4:
            return .kdbx4(minor: minor)
        default:
            throw ParseError.unsupportedVersion(major)
        }
    }

    /// The KDBX 4 outer header fields that follow the version, up to and
    /// including the end-of-header field.
    static func parseOuterHeader(_ reader: inout DataReader) throws -> Header {
        var header = Header()

        while true {
            let fieldID = try reader.readUInt8()
            let fieldSize = Int(try reader.readUInt32())

            switch HeaderField(rawValue: fieldID) {
            case .endOfHeader?:
                try reader.skip(fieldSize)
                return header
            case .cipherID?:
                header.cipherID = try reader.readBytes(fieldSize)
            case .compressionFlags?:
                header.compressionFlags = try reader.readInteger(fieldSize: fieldSize)
            case .masterSeed?:
                header.masterSeed = try reader.readBytes(fieldSize)
            case .encryptionIV?:
                header.encryptionIV = try reader.readBytes(fieldSize)
            case .kdfParameters?:
                header.kdfParameters = try KDBXVariantMap(serialized: reader.readBytes(fieldSize))
            case nil:
                header.unknownOuterHeaderFields.append(
                    UnknownHeaderField(id: fieldID, data: try reader.readBytes(fieldSize))
                )
            }
        }
    }

    /// Stops at the end-of-header field, or at the end of the data for a
    /// producer that omits it.
    static func parseInnerHeader(_ reader: inout DataReader, into header: inout Header) throws {
        while reader.hasMore {
            let fieldID = try reader.readUInt8()
            let fieldSize = Int(try reader.readUInt32())

            switch InnerHeaderField(rawValue: fieldID) {
            case .endOfHeader?:
                try reader.skip(fieldSize)
                return
            case .innerRandomStreamID?:
                header.innerStreamID = try reader.readInteger(fieldSize: fieldSize)
            case .innerRandomStreamKey?:
                header.innerStreamKey = try reader.readBytes(fieldSize)
            case .binary?:
                header.innerHeaderBinaryFields.append(try reader.readBytes(fieldSize))
            case nil:
                header.unknownInnerHeaderFields.append(
                    UnknownHeaderField(id: fieldID, data: try reader.readBytes(fieldSize))
                )
            }
        }
    }

    // MARK: - Keys and Blocks

    /// The keys a KDBX file derives from its master seed and transformed key.
    struct MasterKeys {
        /// SHA-256(masterSeed || transformedKey), the outer cipher key.
        var masterKey: Data
        /// SHA-512(masterSeed || transformedKey || 0x01), the HMAC base key.
        var hmacBaseKey: Data

        init(masterSeed: Data, transformedKey: Data) {
            var transformedKey = transformedKey
            defer { SecureWipe.wipe(&transformedKey) }
            var material = Data(capacity: masterSeed.count + transformedKey.count + 1)
            defer { SecureWipe.wipe(&material) }
            material.append(masterSeed)
            material.append(transformedKey)
            masterKey = KDBXCrypto.sha256(material)
            material.append(0x01)
            hmacBaseKey = KDBXCrypto.sha512(material)
        }

        func headerHMAC(for headerBytes: Data) -> Data {
            var key = KDBXContainer.blockHMACKey(blockIndex: .max, baseKey: hmacBaseKey)
            defer { SecureWipe.wipe(&key) }
            return KDBXCrypto.hmacSHA256(key: key, data: headerBytes)
        }

        mutating func wipe() {
            SecureWipe.wipe(&masterKey)
            SecureWipe.wipe(&hmacBaseKey)
        }
    }

    static func readHMACBlocks(reader: inout DataReader, baseKey: Data) throws -> Data {
        var result = Data()
        var blockIndex: UInt64 = 0

        while true {
            let storedHMAC = try reader.readBytes(32)
            let blockSize = try reader.readInt32()
            guard blockSize >= 0 else { throw ParseError.truncatedFile }
            let blockData = try reader.readBytes(Int(blockSize))

            guard constantTimeEqual(storedHMAC, blockHMAC(blockIndex: blockIndex, block: blockData, baseKey: baseKey)) else {
                throw ParseError.invalidBlockHMAC
            }
            if blockData.isEmpty {
                return result
            }
            result.append(blockData)
            blockIndex += 1
        }
    }

    static func blockHMAC(blockIndex: UInt64, block: Data, baseKey: Data) -> Data {
        var key = blockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
        defer { SecureWipe.wipe(&key) }
        var message = Data(capacity: 12 + block.count)
        message.appendLittleEndian(blockIndex)
        message.appendLittleEndian(Int32(block.count))
        message.append(block)
        return KDBXCrypto.hmacSHA256(key: key, data: message)
    }

    static func blockHMACKey(blockIndex: UInt64, baseKey: Data) -> Data {
        var keyMaterial = Data(capacity: 8 + baseKey.count)
        defer { SecureWipe.wipe(&keyMaterial) }
        keyMaterial.appendLittleEndian(blockIndex)
        keyMaterial.append(baseKey)
        return KDBXCrypto.sha512(keyMaterial)
    }

    private static func looksLikeXML(_ data: Data) -> Bool {
        let utf8BOM = Data([0xEF, 0xBB, 0xBF])
        let text = data.starts(with: utf8BOM) ? data.dropFirst(utf8BOM.count) : data
        return text.starts(with: Data("<?xml".utf8)) || text.starts(with: Data("<KeePassFile".utf8))
    }

    /// Compares in constant time, so a hash or HMAC check leaks no timing.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) {
            difference |= x ^ y
        }
        return difference == 0
    }
}
