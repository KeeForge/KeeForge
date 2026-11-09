import Foundation

// KDBX 3.1: read-only. Its outer header is unauthenticated, the payload is
// checked by stream start bytes and per-block SHA-256 hashes, and AES-KDF is
// the only KDF.
extension KDBXContainer {
    struct LegacyHeader {
        enum Field: UInt8 {
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

        var header = Header(formatVersion: .kdbx3_1)
        var transformSeed = Data()
        var transformRounds: UInt64 = 0
        var streamStartBytes = Data()

        /// Reads the fields after the version. Unknown fields are skipped, as
        /// KeePass does; the result is never written back.
        init(reading reader: inout DataReader) throws {
            while true {
                let fieldID = try reader.readUInt8()
                let fieldSize = Int(try reader.readUInt16())

                switch Field(rawValue: fieldID) {
                case .endOfHeader?:
                    try reader.skip(fieldSize)
                    header.headerData = reader.data.prefix(reader.offset)
                    header.kdfParameters = KDBXKeyDerivation.aesKDF(rounds: transformRounds, seed: transformSeed).parameters
                    return
                case .cipherID?:
                    header.cipherID = try reader.readBytes(fieldSize)
                case .compressionFlags?:
                    header.compressionFlags = try reader.readInteger(fieldSize: fieldSize)
                case .masterSeed?:
                    header.masterSeed = try reader.readBytes(fieldSize)
                case .transformSeed?:
                    transformSeed = try reader.readBytes(fieldSize)
                case .transformRounds?:
                    transformRounds = try reader.readInteger(fieldSize: fieldSize)
                case .encryptionIV?:
                    header.encryptionIV = try reader.readBytes(fieldSize)
                case .protectedStreamKey?:
                    header.innerStreamKey = try reader.readBytes(fieldSize)
                case .streamStartBytes?:
                    streamStartBytes = try reader.readBytes(fieldSize)
                case .innerRandomStreamID?:
                    header.innerStreamID = try reader.readInteger(fieldSize: fieldSize)
                case nil:
                    try reader.skip(fieldSize)
                }
            }
        }
    }

    static func readKDBX3(
        data: Data,
        reader: inout DataReader,
        transformedKey provideTransformedKey: (KDBXVariantMap) throws -> Data
    ) throws -> Payload {
        let legacy = try LegacyHeader(reading: &reader)
        let header = legacy.header
        // Fail on an unreadable protected stream before running the KDF.
        _ = try KDBXInnerStream(streamID: header.innerStreamID, key: Data())

        guard let cipher = header.cipher, cipher.supportsKDBX3 else {
            throw KDBXCrypto.CryptoError.unsupportedCipher(header.cipherID)
        }

        let encryptedPayload = data.subdata(in: reader.offset..<data.count)
        let decrypted: Data
        do {
            var keys = try MasterKeys(masterSeed: header.masterSeed, transformedKey: provideTransformedKey(header.kdfParameters))
            defer { keys.wipe() }
            decrypted = try cipher.decrypt(data: encryptedPayload, key: keys.masterKey, iv: header.encryptionIV)
        } catch KDBXCrypto.CryptoError.decryptionFailed {
            // Wrong credentials usually surface as a padding failure before
            // the stream start bytes can be checked; report both the same way.
            throw ParseError.invalidStreamStartBytes
        }

        let startBytes = legacy.streamStartBytes
        guard decrypted.count >= startBytes.count,
              constantTimeEqual(decrypted.prefix(startBytes.count), startBytes) else {
            throw ParseError.invalidStreamStartBytes
        }

        let blocks = try readHashedBlockStream(decrypted.dropFirst(startBytes.count))
        let xml = header.compressionFlags == Compression.gzip.rawValue
            ? try Gzip.decompress(blocks, maxOutputSize: maxDecompressedPayloadSize)
            : blocks
        return Payload(header: header, xml: xml)
    }

    private static func readHashedBlockStream(_ data: Data) throws -> Data {
        var reader = DataReader(data: Data(data))
        var result = Data()
        var expectedBlockIndex: UInt32 = 0

        while true {
            guard try reader.readUInt32() == expectedBlockIndex else {
                throw ParseError.invalidLegacyBlockHash
            }
            let storedHash = try reader.readBytes(32)
            let blockSize = try reader.readInt32()
            guard blockSize >= 0 else { throw ParseError.truncatedFile }
            let block = try reader.readBytes(Int(blockSize))

            let expectedHash = block.isEmpty ? Data(count: 32) : KDBXCrypto.sha256(block)
            guard constantTimeEqual(storedHash, expectedHash) else {
                throw ParseError.invalidLegacyBlockHash
            }
            if block.isEmpty {
                return result
            }
            result.append(block)
            expectedBlockIndex &+= 1
        }
    }
}
