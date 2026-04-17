import CryptoKit
import Foundation

extension KDBXParser {
    struct LegacyHeader: Sendable {
        var formatVersion: FileVersion = .kdbx3_1
        var cipherID = Data()
        var compressionFlags: UInt32 = 0
        var masterSeed = Data()
        var transformSeed = Data()
        var transformRounds: UInt64 = 0
        var encryptionIV = Data()
        var protectedStreamKey = Data()
        var streamStartBytes = Data()
        var innerRandomStreamID: UInt32 = 0
        var headerData = Data()
        var payloadOffset = 0
    }

    static func parseKDBX3Header(from data: Data) throws -> LegacyHeader {
        var reader = DataReader(data: data)
        let version = try parseVersion(from: &reader)
        guard case .kdbx3_1 = version else {
            throw ParseError.unsupportedVersion(version.majorVersion)
        }

        let headerStart = 0
        var header = try parseLegacyHeader(&reader)
        header.payloadOffset = reader.offset
        header.headerData = data.subdata(in: headerStart..<header.payloadOffset)
        return header
    }

    static func deriveKDBX3MasterKey(
        compositeKey: Data,
        header: LegacyHeader
    ) throws -> Data {
        guard header.transformRounds >= 1, header.transformRounds <= aesKDFMaxRounds else {
            throw ParseError.kdfParameterOutOfRange("rounds \(header.transformRounds) not in 1...\(aesKDFMaxRounds)")
        }

        let transformedKey = try KDBXCrypto.transformKeyAESKDF(
            compositeKey: compositeKey,
            seed: header.transformSeed,
            rounds: header.transformRounds
        )

        var preKey = Data()
        preKey.append(header.masterSeed)
        preKey.append(transformedKey)
        return KDBXCrypto.sha256(preKey)
    }

    static func parseKDBX3WithMetaAndHeader(
        data: Data,
        compositeKey: Data,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: Header) {
        let legacyHeader = try parseKDBX3Header(from: data)
        try validateSupportedProtectedFieldStream(legacyHeader.innerRandomStreamID)

        guard legacyHeader.cipherID == aesCipherUUID else {
            throw KDBXCrypto.CryptoError.unsupportedCipher(legacyHeader.cipherID.hexString)
        }

        let masterKey = try deriveKDBX3MasterKey(compositeKey: compositeKey, header: legacyHeader)
        let encryptedPayload = data.subdata(in: legacyHeader.payloadOffset..<data.count)
        let decryptedPayload = try KDBXCrypto.decryptAES256CBC(
            data: encryptedPayload,
            key: masterKey,
            iv: legacyHeader.encryptionIV
        )

        guard decryptedPayload.count >= legacyHeader.streamStartBytes.count else {
            throw ParseError.invalidStreamStartBytes
        }

        let payloadStartBytes = Data(decryptedPayload.prefix(legacyHeader.streamStartBytes.count))
        guard constantTimeEqual(payloadStartBytes, legacyHeader.streamStartBytes) else {
            throw ParseError.invalidStreamStartBytes
        }

        let blockStream = Data(decryptedPayload.dropFirst(legacyHeader.streamStartBytes.count))
        let xmlPayload = try readHashedBlockStream(blockStream)
        let xmlData = legacyHeader.compressionFlags == 1
            ? try KDBXCrypto.gunzip(xmlPayload)
            : xmlPayload

        let parsed = try parseXML(
            xmlData: xmlData,
            innerStreamKey: legacyHeader.protectedStreamKey,
            innerStreamID: legacyHeader.innerRandomStreamID,
            sessionKey: sessionKey
        )

        var header = Header()
        header.formatVersion = legacyHeader.formatVersion
        header.cipherID = legacyHeader.cipherID
        header.compressionFlags = legacyHeader.compressionFlags
        header.masterSeed = legacyHeader.masterSeed
        header.encryptionIV = legacyHeader.encryptionIV
        header.headerData = legacyHeader.headerData
        header.innerStreamID = legacyHeader.innerRandomStreamID
        header.innerStreamKey = legacyHeader.protectedStreamKey

        return (parsed.rootGroup, parsed.meta, header)
    }

    private static func parseLegacyHeader(_ reader: inout DataReader) throws -> LegacyHeader {
        var header = LegacyHeader()

        while reader.hasMore {
            let fieldID = try reader.readUInt8()
            let fieldSize = Int(try reader.readUInt16())

            guard let field = LegacyHeaderField(rawValue: fieldID) else {
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
            case .transformSeed:
                header.transformSeed = try reader.readBytes(fieldSize)
            case .transformRounds:
                header.transformRounds = try reader.readUInt64From(fieldSize)
            case .encryptionIV:
                header.encryptionIV = try reader.readBytes(fieldSize)
            case .protectedStreamKey:
                header.protectedStreamKey = try reader.readBytes(fieldSize)
            case .streamStartBytes:
                header.streamStartBytes = try reader.readBytes(fieldSize)
            case .innerRandomStreamID:
                header.innerRandomStreamID = try reader.readUInt32From(fieldSize)
            }
        }

        throw ParseError.truncatedFile
    }

    private static func readHashedBlockStream(_ data: Data) throws -> Data {
        var reader = DataReader(data: data)
        var result = Data()
        var expectedBlockIndex: UInt32 = 0

        while reader.hasMore {
            let blockIndex = try reader.readUInt32()
            guard blockIndex == expectedBlockIndex else {
                throw ParseError.invalidLegacyBlockHash
            }

            let storedHash = try reader.readBytes(32)
            let blockSizeRaw = try reader.readInt32()
            guard blockSizeRaw >= 0 else {
                throw ParseError.truncatedFile
            }

            if blockSizeRaw == 0 {
                let zeroHash = Data(repeating: 0, count: 32)
                guard constantTimeEqual(storedHash, zeroHash) else {
                    throw ParseError.invalidLegacyBlockHash
                }
                return result
            }

            let blockData = try reader.readBytes(Int(blockSizeRaw))
            let computedHash = KDBXCrypto.sha256(blockData)
            guard constantTimeEqual(storedHash, computedHash) else {
                throw ParseError.invalidLegacyBlockHash
            }

            result.append(blockData)
            expectedBlockIndex &+= 1
        }

        throw ParseError.truncatedFile
    }

    static func validateSupportedProtectedFieldStream(_ streamID: UInt32) throws {
        switch streamID {
        case innerStreamNone, innerStreamSalsa20, innerStreamChaCha20:
            return
        default:
            throw ParseError.unsupportedProtectedFieldStream(streamID)
        }
    }
}

private extension DataReader {
    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(8)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    mutating func readUInt64From(_ size: Int) throws -> UInt64 {
        let bytes = try readBytes(size)
        guard bytes.count >= 8 else { throw KDBXParser.ParseError.truncatedFile }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }
}
