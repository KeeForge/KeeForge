import Foundation
import Security

/// Writes the KDBX 4 container around database XML the caller serialized.
///
/// Saving is three steps because protected XML values are masked with the
/// inner stream key of the header being written: `prepareHeader` fixes that
/// header (fresh master seed, IV, inner stream key, and KDF salt on every
/// save), the caller serializes against `header.innerStreamKey` with a
/// `KDBXInnerStream`, and `seal` encrypts and frames the result.
public enum KDBXContainerWriter {
    public struct FreshHeaderConfiguration: Hashable, Sendable {
        public var cipher: KDBXOuterCipher
        public var kdfParameters: KDBXVariantMap
        /// The binary pool, each item with its leading flags byte.
        public var innerHeaderBinaryFields: [Data]

        public init(
            cipher: KDBXOuterCipher,
            kdfParameters: KDBXVariantMap,
            innerHeaderBinaryFields: [Data] = []
        ) {
            self.cipher = cipher
            self.kdfParameters = kdfParameters
            self.innerHeaderBinaryFields = innerHeaderBinaryFields
        }
    }

    public enum WriteError: Error, Hashable, Sendable {
        /// KDBX 3.1 is read-only.
        case unsupportedSourceFormat(KDBXContainer.FileVersion)
        case unsupportedInnerRandomStream(UInt32)
        case unsupportedCompression(UInt32)
        /// The payload is larger than `KDBXContainer.maxDecompressedPayloadSize`.
        case payloadTooLarge
        case randomGenerationFailed(Int32)
    }

    public enum HeaderSource: Hashable, Sendable {
        /// Saves over an opened file's header, keeping its cipher, KDF cost,
        /// compression, binary pool, and unknown fields.
        case reuse(KDBXContainer.Header)
        /// A new file, gzip-compressed.
        case fresh(FreshHeaderConfiguration)
    }

    private static let hmacBlockSize = 1_048_576
    private static let innerStreamKeyLength = 64
    private static let masterSeedLength = 32
    private static let defaultKDFSaltLength = 32

    /// The header to serialize against and then seal: `source` with a fresh
    /// master seed, IV, inner stream key, and KDF salt, and a ChaCha20 inner
    /// stream. Only the KDF cost parameters carry over, as in KeePass and
    /// KeePassXC.
    ///
    /// The minor version becomes `max(existing, requiredMinorVersion)`, the
    /// lowest one that can represent the content, never a downgrade: a reused
    /// header may describe 4.1 XML the caller kept verbatim. The same policy as
    /// KeePassXC's `KeePass2Writer::kdbxVersionRequired`.
    public static func prepareHeader(
        _ source: HeaderSource,
        requiredMinorVersion: UInt16
    ) throws -> KDBXContainer.Header {
        var header: KDBXContainer.Header
        switch source {
        case .reuse(let existing):
            guard case .kdbx4(let minor) = existing.formatVersion else {
                throw WriteError.unsupportedSourceFormat(existing.formatVersion)
            }
            header = existing
            header.formatVersion = .kdbx4(minor: max(minor, requiredMinorVersion))
        case .fresh(let configuration):
            header = KDBXContainer.Header(
                formatVersion: .kdbx4(minor: requiredMinorVersion),
                cipherID: configuration.cipher.uuid,
                compressionFlags: KDBXContainer.Compression.gzip.rawValue,
                kdfParameters: configuration.kdfParameters,
                innerHeaderBinaryFields: configuration.innerHeaderBinaryFields
            )
        }

        let chaCha20 = KDBXInnerStream.Algorithm.chaCha20.rawValue
        if header.innerStreamID == KDBXInnerStream.Algorithm.unprotected.rawValue {
            header.innerStreamID = chaCha20
        }
        guard header.innerStreamID == chaCha20 else {
            throw WriteError.unsupportedInnerRandomStream(header.innerStreamID)
        }
        guard header.compression != nil else {
            throw WriteError.unsupportedCompression(header.compressionFlags)
        }
        let cipher = try KDBXOuterCipher.require(uuid: header.cipherID)

        header.masterSeed = try randomData(count: masterSeedLength)
        header.encryptionIV = try randomData(count: cipher.encryptionIVLength)
        header.innerStreamKey = try randomData(count: innerStreamKeyLength)
        let existingSaltLength = header.kdfParameters.bytes("S")?.count ?? 0
        let saltLength = existingSaltLength > 0 ? existingSaltLength : defaultKDFSaltLength
        header.kdfParameters["S"] = .bytes(try randomData(count: saltLength))
        header.headerData = Data()
        return header
    }

    /// Encrypts and frames `xml`, serialized against `header.innerStreamKey`,
    /// into a KDBX 4 file. `header` comes from `prepareHeader`.
    /// `transformedKey` receives the KDF parameters the file is written with
    /// (the rotated salt included) and returns the KDF output.
    public static func seal(
        xml: Data,
        header: KDBXContainer.Header,
        transformedKey provideTransformedKey: (_ kdfParameters: KDBXVariantMap) throws -> Data
    ) throws -> Data {
        var payload = innerHeader(of: header)
        payload.append(xml)

        if header.compressionFlags == KDBXContainer.Compression.gzip.rawValue {
            guard payload.count <= KDBXContainer.maxDecompressedPayloadSize else {
                throw WriteError.payloadTooLarge
            }
            payload = try Gzip.compress(payload)
        }

        let cipher = try KDBXOuterCipher.require(uuid: header.cipherID)
        var keys = try KDBXContainer.MasterKeys(
            masterSeed: header.masterSeed,
            transformedKey: provideTransformedKey(header.kdfParameters)
        )
        defer { keys.wipe() }

        let encryptedPayload = try cipher.encrypt(data: payload, key: keys.masterKey, iv: header.encryptionIV)
        let outerHeader = outerHeader(of: header)

        var output = outerHeader
        output.append(KDBXCrypto.sha256(outerHeader))
        output.append(keys.headerHMAC(for: outerHeader))
        output.append(hmacBlocks(encryptedPayload, baseKey: keys.hmacBaseKey))
        return output
    }

    private static func outerHeader(of header: KDBXContainer.Header) -> Data {
        var data = Data()
        data.appendLittleEndian(KDBXContainer.signature1)
        data.appendLittleEndian(KDBXContainer.signature2)
        data.appendLittleEndian(header.formatVersion.minorVersion)
        data.appendLittleEndian(header.formatVersion.majorVersion)

        typealias Field = KDBXContainer.HeaderField
        appendField(Field.cipherID.rawValue, header.cipherID, to: &data)
        appendField(Field.compressionFlags.rawValue, Data(littleEndian: header.compressionFlags), to: &data)
        appendField(Field.masterSeed.rawValue, header.masterSeed, to: &data)
        appendField(Field.encryptionIV.rawValue, header.encryptionIV, to: &data)
        appendField(Field.kdfParameters.rawValue, header.kdfParameters.serialized(), to: &data)
        for field in header.unknownOuterHeaderFields {
            appendField(field.id, field.data, to: &data)
        }
        appendField(Field.endOfHeader.rawValue, Data(), to: &data)
        return data
    }

    /// Unknown fields go between the stream fields and the binary pool, in
    /// their original relative order. KDBX 4 defines no ordering beyond the
    /// terminator and KeePassXC skips IDs it does not know; pool edits would
    /// move them if they were written at their original offsets.
    private static func innerHeader(of header: KDBXContainer.Header) -> Data {
        var data = Data()
        typealias Field = KDBXContainer.InnerHeaderField
        appendField(Field.innerRandomStreamID.rawValue, Data(littleEndian: header.innerStreamID), to: &data)
        appendField(Field.innerRandomStreamKey.rawValue, header.innerStreamKey, to: &data)
        for field in header.unknownInnerHeaderFields {
            appendField(field.id, field.data, to: &data)
        }
        for binary in header.innerHeaderBinaryFields {
            appendField(Field.binary.rawValue, binary, to: &data)
        }
        appendField(Field.endOfHeader.rawValue, Data(), to: &data)
        return data
    }

    private static func appendField(_ id: UInt8, _ value: Data, to data: inout Data) {
        data.append(id)
        data.appendLittleEndian(UInt32(value.count))
        data.append(value)
    }

    /// Ends with the empty terminating block.
    private static func hmacBlocks(_ data: Data, baseKey: Data) -> Data {
        var framed = Data()
        var blockIndex: UInt64 = 0
        var offset = 0

        while true {
            let blockSize = min(hmacBlockSize, data.count - offset)
            let block = data.subdata(in: offset..<(offset + blockSize))
            framed.append(KDBXContainer.blockHMAC(blockIndex: blockIndex, block: block, baseKey: baseKey))
            framed.appendLittleEndian(Int32(blockSize))
            framed.append(block)
            if block.isEmpty {
                return framed
            }
            offset += blockSize
            blockIndex += 1
        }
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw WriteError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}
