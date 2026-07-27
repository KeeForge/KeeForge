import CryptoKit
import Foundation

enum KDBXWriter {
    struct FreshHeaderConfiguration {
        let cipherID: Data
        let kdfParameters: [String: Any]
        var innerStreamID: UInt32
        var innerHeaderBinaryFields: [Data]

        init(
            cipherID: Data,
            kdfParameters: [String: Any],
            innerStreamID: UInt32 = KDBXParser.innerStreamChaCha20,
            innerHeaderBinaryFields: [Data] = []
        ) {
            self.cipherID = cipherID
            self.kdfParameters = kdfParameters
            self.innerStreamID = innerStreamID
            self.innerHeaderBinaryFields = innerHeaderBinaryFields
        }
    }

    enum WriteError: Error, LocalizedError {
        case unsupportedSourceFormat(KDBXParser.FileVersion)
        case unsupportedInnerRandomStream(UInt32)
        case unsupportedCompression(UInt32)
        case unsupportedVariantMapValue(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSourceFormat:
                String(localized: "Saving legacy KDBX 3.1 databases is not supported yet.")
            case .unsupportedInnerRandomStream(let streamID):
                String(localized: "Unsupported inner random stream: \(streamID)")
            case .unsupportedCompression(let compressionFlags):
                String(localized: "Unsupported compression mode: \(compressionFlags)")
            case .unsupportedVariantMapValue(let key):
                String(localized: "Unsupported variant map value for key: \(key)")
            }
        }
    }

    private enum HeaderSource {
        case reuse(KDBXParser.Header)
        case fresh(FreshHeaderConfiguration)
    }

    private static let defaultHeaderMinorVersion: UInt16 = 0
    private static let hmacBlockSize = 1_048_576
    private static let innerStreamKeyLength = 64
    private static let masterSeedLength = 32
    private static let defaultKDFSaltLength = 32

    static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        compositeKey: Data,
        header: KDBXParser.Header,
        sessionKey: SymmetricKey
    ) throws -> Data {
        try write(
            rootGroup: rootGroup,
            meta: meta,
            compositeKey: compositeKey,
            sessionKey: sessionKey,
            headerSource: .reuse(header)
        )
    }

    static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        compositeKey: Data,
        freshHeader: FreshHeaderConfiguration,
        sessionKey: SymmetricKey
    ) throws -> Data {
        try write(
            rootGroup: rootGroup,
            meta: meta,
            compositeKey: compositeKey,
            sessionKey: sessionKey,
            headerSource: .fresh(freshHeader)
        )
    }

    private static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        compositeKey: Data,
        sessionKey: SymmetricKey,
        headerSource: HeaderSource
    ) throws -> Data {
        let header = try resolveHeader(from: headerSource)
        let keys = try deriveKeys(compositeKey: compositeKey, header: header)

        let outerHeader = try buildOuterHeader(from: header)

        var serializer = KDBXXMLSerializer(
            rootGroup: rootGroup,
            meta: meta,
            innerStreamKey: header.innerStreamKey,
            sessionKey: sessionKey
        )
        let xmlData = try serializer.serialize()

        var payload = buildInnerHeader(from: header)
        payload.append(xmlData)

        // KeePassXC writes KDBX4 payloads with gzip enabled by default.
        let payloadToEncrypt: Data
        switch header.compressionFlags {
        case 0:
            payloadToEncrypt = payload
        case 1:
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
        let headerHMACKey = KDBXParser.computeBlockHMACKey(
            blockIndex: UInt64.max,
            baseKey: keys.hmacBaseKey
        )
        let headerHMAC = KDBXCrypto.hmacSHA256(key: headerHMACKey, data: outerHeader)
        let framedPayload = frameIntoHMACBlocks(encryptedPayload, baseKey: keys.hmacBaseKey)

        var output = Data()
        output.append(outerHeader)
        output.append(headerSHA256)
        output.append(headerHMAC)
        output.append(framedPayload)
        return output
    }

    private static func resolveHeader(from source: HeaderSource) throws -> KDBXParser.Header {
        var header: KDBXParser.Header

        switch source {
        case .reuse(let existing):
            guard existing.formatVersion.majorVersion == KDBXParser.versionKDBX4 else {
                throw WriteError.unsupportedSourceFormat(existing.formatVersion)
            }
            header = existing
        case .fresh(let configuration):
            header = KDBXParser.Header(
                formatVersion: .kdbx4(minor: defaultHeaderMinorVersion),
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
            header.innerStreamID = KDBXParser.innerStreamChaCha20
        }

        guard header.innerStreamID == KDBXParser.innerStreamChaCha20 else {
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
        compositeKey: Data,
        header: KDBXParser.Header
    ) throws -> (masterKey: Data, hmacBaseKey: Data) {
        let transformedKey = try KDBXParser.deriveKey(
            compositeKey: compositeKey,
            kdfParams: header.kdfParameters
        )

        var masterPreKey = Data()
        masterPreKey.append(header.masterSeed)
        masterPreKey.append(transformedKey)
        let masterKey = KDBXCrypto.sha256(masterPreKey)

        var hmacPreKey = Data()
        hmacPreKey.append(header.masterSeed)
        hmacPreKey.append(transformedKey)
        hmacPreKey.append(Data([0x01]))
        let hmacBaseKey = KDBXCrypto.sha512(hmacPreKey)

        return (masterKey, hmacBaseKey)
    }

    private static func buildOuterHeader(from header: KDBXParser.Header) throws -> Data {
        var outerHeader = Data()
        outerHeader.appendLE(KDBXParser.kdbxSignature1)
        outerHeader.appendLE(KDBXParser.kdbxSignature2)
        outerHeader.appendLE(header.formatVersion.minorVersion)
        outerHeader.appendLE(KDBXParser.versionKDBX4)

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

    private static func buildInnerHeader(from header: KDBXParser.Header) -> Data {
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

            let hmacKey = KDBXParser.computeBlockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
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

        let finalHMACKey = KDBXParser.computeBlockHMACKey(blockIndex: blockIndex, baseKey: baseKey)
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
        field: KDBXParser.HeaderField,
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
        field: KDBXParser.InnerHeaderField,
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

    private static func randomData(count: Int) throws -> Data {
        try SecureRandom.data(count: count)
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
