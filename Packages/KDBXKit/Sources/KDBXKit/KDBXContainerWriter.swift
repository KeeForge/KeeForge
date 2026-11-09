import CryptoKit
import Foundation
import Security

/// Writes the KDBX 4 container around database XML the caller serialized.
///
/// Saving is two steps because protected XML values are masked with the inner
/// stream key of the header being written: `prepareHeader` fixes that header
/// (fresh seeds, IV, stream key, and KDF salt on every save), the caller
/// serializes against `header.innerStreamKey`, and `seal` encrypts and frames.
public enum KDBXContainerWriter {
    public struct FreshHeaderConfiguration: @unchecked Sendable {
        public let cipherID: Data
        public let kdfParameters: [String: Any]
        public var innerStreamID: UInt32
        public var innerHeaderBinaryFields: [Data]

        public init(
            cipherID: Data,
            kdfParameters: [String: Any],
            innerStreamID: UInt32 = KDBXContainer.innerStreamChaCha20,
            innerHeaderBinaryFields: [Data] = []
        ) {
            self.cipherID = cipherID
            self.kdfParameters = kdfParameters
            self.innerStreamID = innerStreamID
            self.innerHeaderBinaryFields = innerHeaderBinaryFields
        }
    }

    public enum WriteError: Error, Equatable, Sendable {
        case unsupportedSourceFormat(KDBXContainer.FileVersion)
        case unsupportedInnerRandomStream(UInt32)
        case unsupportedCompression(UInt32)
        case unsupportedVariantMapValue(String)
        case payloadTooLarge
        case randomGenerationFailed(Int32)
    }

    public enum HeaderSource: Sendable {
        /// Saves over an opened file's header, keeping its cipher, KDF cost,
        /// compression, binary pool, and unknown fields.
        case reuse(KDBXContainer.Header)
        case fresh(FreshHeaderConfiguration)
    }

    private static let defaultHeaderMinorVersion: UInt16 = 0
    private static let hmacBlockSize = 1_048_576
    private static let innerStreamKeyLength = 64
    private static let masterSeedLength = 32
    private static let defaultKDFSaltLength = 32

    /// Seals `xml`, serialized against `header.innerStreamKey`, into a file.
    /// `transformedKey` receives the KDF parameters the file is written with
    /// (the rotated salt included) and returns the KDF output.
    public static func seal(
        xml: Data,
        header: KDBXContainer.Header,
        transformedKey provideTransformedKey: (_ kdfParameters: [String: Any]) throws -> Data
    ) throws -> Data {
        var keys = try deriveKeys(header: header, provideTransformedKey: provideTransformedKey)
        defer {
            SecureWipe.wipe(&keys.masterKey)
            SecureWipe.wipe(&keys.hmacBaseKey)
        }

        let outerHeader = try buildOuterHeader(from: header)

        var payload = buildInnerHeader(from: header)
        payload.append(xml)

        // KeePassXC writes KDBX4 payloads with gzip enabled by default.
        let payloadToEncrypt: Data
        switch header.compressionFlags {
        case 0:
            payloadToEncrypt = payload
        case 1:
            guard payload.count <= KDBXCrypto.maxDecompressedSize else {
                throw WriteError.payloadTooLarge
            }
            payloadToEncrypt = try KDBXCrypto.gzip(payload)
        default:
            throw WriteError.unsupportedCompression(header.compressionFlags)
        }
        let encryptedPayload = try encryptPayload(
            payloadToEncrypt,
            cipherID: header.cipherID,
            masterKey: keys.masterKey,
            encryptionIV: header.encryptionIV
        )

        let headerSHA256 = KDBXCrypto.sha256(outerHeader)
        var headerHMACKey = KDBXContainer.computeBlockHMACKey(
            blockIndex: UInt64.max,
            baseKey: keys.hmacBaseKey
        )
        defer { SecureWipe.wipe(&headerHMACKey) }
        let headerHMAC = KDBXCrypto.hmacSHA256(key: headerHMACKey, data: outerHeader)
        let framedPayload = frameIntoHMACBlocks(encryptedPayload, baseKey: keys.hmacBaseKey)

        var output = Data()
        output.append(outerHeader)
        output.append(headerSHA256)
        output.append(headerHMAC)
        output.append(framedPayload)
        return output
    }

    /// Resolves the header to write, raising its minor version to
    /// `requiredMinorVersion`, the lowest one that can represent the content.
    ///
    /// Same policy as KeePassXC's `KeePass2Writer::kdbxVersionRequired` and
    /// KeePassium: `max(required, existing)`, silently, and never a downgrade —
    /// a reused header may describe 4.1 XML the caller kept verbatim, so writing
    /// a 4.0 header over it would misdescribe the payload. KDBX 3.1 sources are
    /// rejected (`FileVersion.requiresReadOnlyMode`).
    public static func prepareHeader(
        _ source: HeaderSource,
        requiredMinorVersion: UInt16
    ) throws -> KDBXContainer.Header {
        var header: KDBXContainer.Header

        switch source {
        case .reuse(let existing):
            guard existing.formatVersion.majorVersion == KDBXContainer.versionKDBX4 else {
                throw WriteError.unsupportedSourceFormat(existing.formatVersion)
            }
            header = existing
            header.formatVersion = .kdbx4(
                minor: max(existing.formatVersion.minorVersion, requiredMinorVersion)
            )
        case .fresh(let configuration):
            header = KDBXContainer.Header(
                formatVersion: .kdbx4(minor: max(defaultHeaderMinorVersion, requiredMinorVersion)),
                cipherID: configuration.cipherID,
                compressionFlags: 1,
                masterSeed: Data(),
                encryptionIV: Data(),
                kdfParameters: configuration.kdfParameters,
                headerData: Data(),
                innerStreamID: configuration.innerStreamID,
                innerStreamKey: Data(),
                innerHeaderBinaryFields: configuration.innerHeaderBinaryFields
            )
        }

        if header.innerStreamID == 0 {
            header.innerStreamID = KDBXContainer.innerStreamChaCha20
        }

        guard header.innerStreamID == KDBXContainer.innerStreamChaCha20 else {
            throw WriteError.unsupportedInnerRandomStream(header.innerStreamID)
        }

        guard header.compressionFlags == 0 || header.compressionFlags == 1 else {
            throw WriteError.unsupportedCompression(header.compressionFlags)
        }

        // KeePass 2.x / KeePassXC generate fresh random header material on
        // every save; only the KDF cost parameters (iterations, memory,
        // parallelism) carry over — the salt value itself must rotate.
        header.masterSeed = try randomData(count: masterSeedLength)
        header.encryptionIV = try randomData(count: try encryptionIVLength(for: header.cipherID))
        header.innerStreamKey = try randomData(count: innerStreamKeyLength)
        header.kdfParameters["S"] = try randomData(count: kdfSaltLength(for: header.kdfParameters))

        return header
    }

    private static func kdfSaltLength(for kdfParameters: [String: Any]) -> Int {
        if let existingSalt = kdfParameters["S"] as? Data, !existingSalt.isEmpty {
            return existingSalt.count
        }
        return defaultKDFSaltLength
    }

    private static func deriveKeys(
        header: KDBXContainer.Header,
        provideTransformedKey: (_ kdfParameters: [String: Any]) throws -> Data
    ) throws -> (masterKey: Data, hmacBaseKey: Data) {
        var transformedKey = try provideTransformedKey(header.kdfParameters)
        defer { SecureWipe.wipe(&transformedKey) }

        var masterPreKey = Data(capacity: 64)
        defer { SecureWipe.wipe(&masterPreKey) }
        masterPreKey.append(header.masterSeed)
        masterPreKey.append(transformedKey)
        let masterKey = KDBXCrypto.sha256(masterPreKey)

        var hmacPreKey = Data(capacity: 65)
        defer { SecureWipe.wipe(&hmacPreKey) }
        hmacPreKey.append(header.masterSeed)
        hmacPreKey.append(transformedKey)
        hmacPreKey.append(Data([0x01]))
        let hmacBaseKey = KDBXCrypto.sha512(hmacPreKey)

        return (masterKey, hmacBaseKey)
    }

    private static func buildOuterHeader(from header: KDBXContainer.Header) throws -> Data {
        var outerHeader = Data()
        outerHeader.appendLE(KDBXContainer.kdbxSignature1)
        outerHeader.appendLE(KDBXContainer.kdbxSignature2)
        outerHeader.appendLE(header.formatVersion.minorVersion)
        outerHeader.appendLE(KDBXContainer.versionKDBX4)

        appendHeaderField(&outerHeader, field: .cipherID, value: header.cipherID)

        var compressionFlags = Data()
        compressionFlags.appendLE(header.compressionFlags)
        appendHeaderField(&outerHeader, field: .compressionFlags, value: compressionFlags)

        appendHeaderField(&outerHeader, field: .masterSeed, value: header.masterSeed)
        appendHeaderField(&outerHeader, field: .encryptionIV, value: header.encryptionIV)
        appendHeaderField(&outerHeader, field: .kdfParameters, value: try writeVariantMap(header.kdfParameters))
        for field in header.unknownOuterHeaderFields {
            appendRawHeaderField(&outerHeader, id: field.id, value: field.data)
        }
        appendHeaderField(&outerHeader, field: .endOfHeader, value: Data())

        return outerHeader
    }

    private static func buildInnerHeader(from header: KDBXContainer.Header) -> Data {
        var innerHeader = Data()

        var innerStreamID = Data()
        innerStreamID.appendLE(header.innerStreamID)
        appendInnerHeaderField(&innerHeader, field: .innerRandomStreamID, value: innerStreamID)
        appendInnerHeaderField(&innerHeader, field: .innerRandomStreamKey, value: header.innerStreamKey)

        // KDBX4 defines no ordering semantics for inner-header items beyond the
        // 0x00 terminator, and KeePassXC skips IDs it doesn't recognize, so
        // unknown fields are re-emitted byte-exact in their original relative
        // order here — between the stream fields and the binary pool — rather
        // than at their original offsets among pool entries, which edits move.
        for field in header.unknownInnerHeaderFields {
            appendRawInnerHeaderField(&innerHeader, id: field.id, value: field.data)
        }

        for binaryField in header.innerHeaderBinaryFields {
            appendInnerHeaderField(&innerHeader, field: .binary, value: binaryField)
        }

        appendInnerHeaderField(&innerHeader, field: .endOfHeader, value: Data())
        return innerHeader
    }

    private static func encryptPayload(
        _ data: Data,
        cipherID: Data,
        masterKey: Data,
        encryptionIV: Data
    ) throws -> Data {
        let cipher = try KDBXOuterCipher.require(uuid: cipherID)
        return try cipher.encrypt(data: data, key: masterKey, iv: encryptionIV)
    }

    private static func frameIntoHMACBlocks(_ data: Data, baseKey: Data) -> Data {
        var framed = Data()
        var blockIndex: UInt64 = 0
        var offset = 0

        while offset < data.count {
            let blockSize = min(hmacBlockSize, data.count - offset)
            let blockData = data.subdata(in: offset..<(offset + blockSize))

            var hmacKey = KDBXContainer.computeBlockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
            defer { SecureWipe.wipe(&hmacKey) }
            var message = Data()
            message.append(withUInt64: blockIndex)
            message.append(withInt32: Int32(blockSize))
            message.append(blockData)

            let hmac = KDBXCrypto.hmacSHA256(key: hmacKey, data: message)
            framed.append(hmac)
            framed.append(withInt32: Int32(blockSize))
            framed.append(blockData)

            offset += blockSize
            blockIndex &+= 1
        }

        var finalHMACKey = KDBXContainer.computeBlockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
        defer { SecureWipe.wipe(&finalHMACKey) }
        var finalMessage = Data()
        finalMessage.append(withUInt64: blockIndex)
        finalMessage.append(withInt32: 0)

        let finalHMAC = KDBXCrypto.hmacSHA256(key: finalHMACKey, data: finalMessage)
        framed.append(finalHMAC)
        framed.append(withInt32: 0)

        return framed
    }

    private static func writeVariantMap(_ values: [String: Any]) throws -> Data {
        var data = Data()
        data.appendLE(UInt16(0x0100))

        for key in values.keys.sorted() {
            let value = values[key]

            switch value {
            case let value as UInt32:
                appendVariantEntry(&data, type: 0x04, key: key, value: encode(value))
            case let value as UInt64:
                appendVariantEntry(&data, type: 0x05, key: key, value: encode(value))
            case let value as Bool:
                appendVariantEntry(&data, type: 0x08, key: key, value: Data([value ? 1 : 0]))
            case let value as Int32:
                appendVariantEntry(&data, type: 0x0C, key: key, value: encode(value))
            case let value as Int64:
                appendVariantEntry(&data, type: 0x0D, key: key, value: encode(value))
            case let value as String:
                appendVariantEntry(&data, type: 0x18, key: key, value: Data(value.utf8))
            case let value as Data:
                appendVariantEntry(&data, type: 0x42, key: key, value: value)
            case nil:
                throw WriteError.unsupportedVariantMapValue(key)
            default:
                throw WriteError.unsupportedVariantMapValue(key)
            }
        }

        data.append(0x00)
        return data
    }

    private static func appendHeaderField(
        _ data: inout Data,
        field: KDBXContainer.HeaderField,
        value: Data
    ) {
        appendRawHeaderField(&data, id: field.rawValue, value: value)
    }

    private static func appendRawHeaderField(
        _ data: inout Data,
        id: UInt8,
        value: Data
    ) {
        data.append(id)
        data.appendLE(UInt32(value.count))
        data.append(value)
    }

    private static func appendInnerHeaderField(
        _ data: inout Data,
        field: KDBXContainer.InnerHeaderField,
        value: Data
    ) {
        appendRawInnerHeaderField(&data, id: field.rawValue, value: value)
    }

    private static func appendRawInnerHeaderField(
        _ data: inout Data,
        id: UInt8,
        value: Data
    ) {
        data.append(id)
        data.appendLE(UInt32(value.count))
        data.append(value)
    }

    private static func appendVariantEntry(
        _ data: inout Data,
        type: UInt8,
        key: String,
        value: Data
    ) {
        data.append(type)
        let keyData = Data(key.utf8)
        data.appendLE(UInt32(keyData.count))
        data.append(keyData)
        data.appendLE(UInt32(value.count))
        data.append(value)
    }

    private static func encode<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

    private static func encryptionIVLength(for cipherID: Data) throws -> Int {
        try KDBXOuterCipher.require(uuid: cipherID).encryptionIVLength
    }

    static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw WriteError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
