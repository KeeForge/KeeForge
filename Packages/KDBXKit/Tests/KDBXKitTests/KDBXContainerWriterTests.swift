import CryptoKit
import XCTest
@testable import KDBXKit

final class KDBXContainerWriterTests: XCTestCase {
    private typealias B = KDBX4Builder
    private typealias Writer = KDBXContainerWriter

    private let transformedKey = Data(repeating: 0x42, count: 32)
    private let xml = KDBX4Builder.xml

    private func seal(_ xml: Data, _ header: KDBXContainer.Header) throws -> Data {
        try Writer.seal(xml: xml, header: header) { _ in transformedKey }
    }

    private func fresh(
        cipher: KDBXOuterCipher = .aes256CBC,
        kdf: KDBXVariantMap = TestKDF.cheapAESKDF(),
        binaries: [Data] = [],
        minor: UInt16 = 0
    ) throws -> KDBXContainer.Header {
        try Writer.prepareHeader(.fresh(.init(cipher: cipher, kdfParameters: kdf, innerHeaderBinaryFields: binaries)), requiredMinorVersion: minor)
    }

    private struct Item: Equatable {
        let id: UInt8
        let value: Data
    }

    /// The decrypted, decompressed inner header items of a written file, in
    /// file order, read without the library's inner header parser.
    private func innerHeaderItems(of file: Data, transformedKey: Data) throws -> [Item] {
        var reader = DataReader(data: file)
        _ = try KDBXContainer.parseVersion(from: &reader)
        let header = try KDBXContainer.parseOuterHeader(&reader)
        try reader.skip(64)
        let keys = KDBXContainer.MasterKeys(masterSeed: header.masterSeed, transformedKey: transformedKey)
        let encrypted = try KDBXContainer.readHMACBlocks(reader: &reader, baseKey: keys.hmacBaseKey)
        var payload = try KDBXOuterCipher.require(uuid: header.cipherID).decrypt(data: encrypted, key: keys.masterKey, iv: header.encryptionIV)
        if header.compressionFlags == 1 {
            payload = try Gzip.decompress(payload, maxOutputSize: .max)
        }
        var items: [Item] = []
        var inner = DataReader(data: payload)
        while true {
            let id = try inner.readUInt8()
            let value = try inner.readBytes(Int(try inner.readUInt32()))
            items.append(Item(id: id, value: value))
            if id == 0 { return items }
        }
    }

    // MARK: - prepareHeader

    func testFreshHeader() throws {
        let binary = Data([0x01, 0xAA])
        let header = try fresh(cipher: .chaCha20, kdf: TestKDF.cheapArgon2(), binaries: [binary], minor: 1)
        XCTAssertEqual(header.formatVersion, .kdbx4(minor: 1))
        XCTAssertEqual(header.cipher, .chaCha20)
        XCTAssertEqual(header.compression, .gzip)
        XCTAssertEqual(header.masterSeed.count, 32)
        XCTAssertEqual(header.encryptionIV.count, 12)
        XCTAssertEqual(header.innerStreamID, KDBXInnerStream.Algorithm.chaCha20.rawValue)
        XCTAssertEqual(header.innerStreamKey.count, 64)
        XCTAssertEqual(header.innerHeaderBinaryFields, [binary])
        XCTAssertEqual(header.headerData, Data())
        XCTAssertTrue(header.unknownOuterHeaderFields.isEmpty)

        var expectedKDF = TestKDF.cheapArgon2()
        expectedKDF["S"] = header.kdfParameters["S"]
        XCTAssertEqual(header.kdfParameters, expectedKDF, "only the salt changes")
        XCTAssertNotEqual(header.kdfParameters.bytes("S"), TestKDF.cheapArgon2().bytes("S"))
    }

    func testFreshConfigurationDefaults() {
        let configuration = Writer.FreshHeaderConfiguration(cipher: .twofish256CBC, kdfParameters: [:])
        XCTAssertEqual(configuration.innerHeaderBinaryFields, [])
        XCTAssertEqual(configuration.cipher, .twofish256CBC)
    }

    func testEveryPreparedHeaderRotatesItsSecrets() throws {
        let first = try fresh(), second = try fresh()
        XCTAssertNotEqual(first.masterSeed, second.masterSeed)
        XCTAssertNotEqual(first.encryptionIV, second.encryptionIV)
        XCTAssertNotEqual(first.innerStreamKey, second.innerStreamKey)
        XCTAssertNotEqual(first.kdfParameters.bytes("S"), second.kdfParameters.bytes("S"))

        let reused = try Writer.prepareHeader(.reuse(first), requiredMinorVersion: 0)
        XCTAssertNotEqual(reused.masterSeed, first.masterSeed)
        XCTAssertNotEqual(reused.encryptionIV, first.encryptionIV)
        XCTAssertNotEqual(reused.innerStreamKey, first.innerStreamKey)
        XCTAssertNotEqual(reused.kdfParameters.bytes("S"), first.kdfParameters.bytes("S"))
    }

    func testReuseKeepsEverythingButTheSecrets() throws {
        let source = try B.read(Fixture.data("unknown-inner-header.kdbx"), transformedKey: Fixture.unknownInnerHeaderTransformedKey).header
        var withOuter = source
        withOuter.unknownOuterHeaderFields = [.init(id: 0x0C, data: Data([1, 2, 3]))]
        let prepared = try Writer.prepareHeader(.reuse(withOuter), requiredMinorVersion: 0)
        XCTAssertEqual(prepared.cipherID, source.cipherID)
        XCTAssertEqual(prepared.compressionFlags, source.compressionFlags)
        XCTAssertEqual(prepared.innerHeaderBinaryFields, source.innerHeaderBinaryFields)
        XCTAssertEqual(prepared.unknownInnerHeaderFields, source.unknownInnerHeaderFields)
        XCTAssertEqual(prepared.unknownOuterHeaderFields, withOuter.unknownOuterHeaderFields)
        XCTAssertEqual(prepared.headerData, Data())
        var costs = prepared.kdfParameters
        costs["S"] = source.kdfParameters["S"]
        XCTAssertEqual(costs, source.kdfParameters)
    }

    func testMinorVersionIsTheMaximumAndNeverDowngrades() throws {
        var source = try fresh(minor: 1)
        XCTAssertEqual(try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 0).formatVersion, .kdbx4(minor: 1))
        source.formatVersion = .kdbx4(minor: 0)
        XCTAssertEqual(try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 1).formatVersion, .kdbx4(minor: 1))
        XCTAssertEqual(try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 0).formatVersion, .kdbx4(minor: 0))
        XCTAssertEqual(try fresh(minor: 0).formatVersion, .kdbx4(minor: 0))
    }

    func testKDFSaltLengthIsKeptOrDefaulted() throws {
        let short = try fresh(kdf: TestKDF.cheapArgon2(salt: Data(count: 16)))
        XCTAssertEqual(short.kdfParameters.bytes("S")?.count, 16)
        XCTAssertEqual(try fresh(kdf: TestKDF.cheapArgon2(salt: nil)).kdfParameters.bytes("S")?.count, 32)
        XCTAssertEqual(try fresh(kdf: TestKDF.cheapArgon2(salt: Data())).kdfParameters.bytes("S")?.count, 32)
        XCTAssertEqual(try fresh(kdf: TestKDF.cheapAESKDF(seed: Data(count: 64))).kdfParameters.bytes("S")?.count, 64)
        var mistyped = TestKDF.cheapArgon2()
        mistyped["S"] = .string("salt")
        XCTAssertEqual(try fresh(kdf: mistyped).kdfParameters.bytes("S")?.count, 32)
    }

    func testRejectsKDBX3Sources() throws {
        let legacy = try KDBXContainer.readHeader(from: Fixture.data("legacy-kdbx31.kdbx"))
        assertThrows(Writer.WriteError.unsupportedSourceFormat(.kdbx3_1)) {
            try Writer.prepareHeader(.reuse(legacy), requiredMinorVersion: 0)
        }
    }

    func testUpgradesAnUnprotectedStreamAndRejectsOthers() throws {
        var source = try fresh()
        source.innerStreamID = KDBXInnerStream.Algorithm.unprotected.rawValue
        XCTAssertEqual(try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 0).innerStreamID, 3)
        for id: UInt32 in [1, 2, 4] {
            source.innerStreamID = id
            assertThrows(Writer.WriteError.unsupportedInnerRandomStream(id)) {
                try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 0)
            }
        }
    }

    func testRejectsUnknownCompressionAndCipher() throws {
        var source = try fresh()
        source.compressionFlags = 2
        assertThrows(Writer.WriteError.unsupportedCompression(2)) { try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 0) }

        source = try fresh()
        source.cipherID = Data(count: 16)
        assertThrows(KDBXCrypto.CryptoError.unsupportedCipher(Data(count: 16))) {
            try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 0)
        }
    }

    // MARK: - seal

    func testSealedFileRoundTripsForEveryCipher() throws {
        for cipher in KDBXOuterCipher.allCases {
            let header = try fresh(cipher: cipher, binaries: [Data([1, 2])], minor: 1)
            var seen: KDBXVariantMap?
            let file = try Writer.seal(xml: xml, header: header) { parameters in
                seen = parameters
                return transformedKey
            }
            XCTAssertEqual(seen, header.kdfParameters, "the rotated salt is what the KDF sees")

            let payload = try B.read(file, transformedKey: transformedKey)
            XCTAssertEqual(payload.xml, xml)
            var expected = header
            expected.headerData = payload.header.headerData
            XCTAssertEqual(payload.header, expected, "\(cipher)")
            XCTAssertFalse(payload.header.headerData.isEmpty)
        }
    }

    func testUncompressedSealStoresThePayloadAsIs() throws {
        var header = try fresh()
        header.compressionFlags = 0
        let file = try seal(xml, header)
        XCTAssertEqual(try B.read(file, transformedKey: transformedKey).xml, xml)
        let items = try innerHeaderItems(of: file, transformedKey: transformedKey)
        XCTAssertEqual(items.map(\.id), [1, 2, 0])
    }

    func testSealedOuterHeaderHashAndHMACAreIndependentlyVerifiable() throws {
        let header = try fresh()
        let file = try seal(xml, header)
        var reader = DataReader(data: file)
        _ = try KDBXContainer.parseVersion(from: &reader)
        _ = try KDBXContainer.parseOuterHeader(&reader)
        let headerBytes = file.prefix(reader.offset)

        let base = Data(SHA512.hash(data: header.masterSeed + transformedKey + Data([1])))
        XCTAssertEqual(file.subdata(in: reader.offset..<(reader.offset + 32)), Data(SHA256.hash(data: headerBytes)))
        XCTAssertEqual(
            file.subdata(in: (reader.offset + 32)..<(reader.offset + 64)),
            B.hmac(headerBytes, key: B.blockKey(index: .max, base: base))
        )
    }

    /// Field order and encoding as KeePass writes them.
    func testOuterHeaderLayout() throws {
        var header = try fresh()
        header.unknownOuterHeaderFields = [.init(id: 0x0C, data: Data([9])), .init(id: 0x99, data: Data())]
        let file = try seal(xml, header)
        let expected = B.versionPrefix() + B.fields([
            (2, header.cipherID),
            (3, Data([1, 0, 0, 0])),
            (4, header.masterSeed),
            (7, header.encryptionIV),
            (11, header.kdfParameters.serialized()),
            (0x0C, Data([9])),
            (0x99, Data()),
            (0, Data()),
        ])
        XCTAssertEqual(file.prefix(expected.count), expected)
        XCTAssertEqual(try B.read(file, transformedKey: transformedKey).header.unknownOuterHeaderFields, header.unknownOuterHeaderFields)
    }

    /// Payloads over 1 MiB span several HMAC blocks; random bytes keep gzip
    /// from shrinking them below one.
    func testLargePayloadSpansSeveralBlocks() throws {
        var generator = SystemRandomNumberGenerator()
        let large = Data((0..<1_500_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let file = try seal(large, try fresh())
        XCTAssertEqual(try B.read(file, transformedKey: transformedKey).xml, large)

        var reader = DataReader(data: file)
        _ = try KDBXContainer.parseVersion(from: &reader)
        _ = try KDBXContainer.parseOuterHeader(&reader)
        try reader.skip(64)
        var sizes: [Int32] = []
        repeat {
            try reader.skip(32)
            sizes.append(try reader.readInt32())
            try reader.skip(Int(sizes.last ?? 0))
        } while sizes.last != 0
        XCTAssertEqual(sizes.count, 3)
        XCTAssertEqual(sizes[0], 1_048_576)
        XCTAssertFalse(reader.hasMore)
    }

    /// An encrypted payload of exactly one block still ends with an empty block.
    func testPayloadOfExactlyOneBlock() throws {
        var header = try fresh(cipher: .chaCha20)
        header.compressionFlags = 0
        let innerHeaderLength = 5 + 4 + 5 + 64 + 5
        let file = try seal(Data(repeating: 0x41, count: 1_048_576 - innerHeaderLength), header)
        let payload = try B.read(file, transformedKey: transformedKey)
        XCTAssertEqual(payload.xml.count, 1_048_576 - innerHeaderLength)
        let headerLength = try KDBXContainer.readHeader(from: file).headerData.count
        XCTAssertEqual(file.count, headerLength + 64 + (36 + 1_048_576) + 36, "one full block and the empty terminator")
        XCTAssertEqual(file.suffix(4), Data(count: 4))
    }

    func testInnerHeaderOrderStreamFieldsUnknownFieldsBinariesTerminator() throws {
        let source = try B.read(Fixture.data("unknown-inner-header.kdbx"), transformedKey: Fixture.unknownInnerHeaderTransformedKey).header
        let header = try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 0)
        let file = try seal(xml, header)

        // The fixture's 0x21, between the two binaries on disk, moves ahead of them.
        let items = try innerHeaderItems(of: file, transformedKey: transformedKey)
        XCTAssertEqual(items.map(\.id), [0x01, 0x02, 0x21, 0x7F, 0x10, 0x03, 0x03, 0x00])
        XCTAssertEqual(items[0].value, Data(littleEndian: UInt32(3)))
        XCTAssertEqual(items[1].value, header.innerStreamKey)
        XCTAssertEqual(items[2...4].map { KDBXContainer.UnknownHeaderField(id: $0.id, data: $0.value) }, source.unknownInnerHeaderFields)
        XCTAssertEqual(items[5...6].map(\.value), source.innerHeaderBinaryFields)
        XCTAssertEqual(items[7].value, Data())

        let reread = try B.read(file, transformedKey: transformedKey).header
        XCTAssertEqual(reread.unknownInnerHeaderFields, source.unknownInnerHeaderFields)
        XCTAssertEqual(reread.innerHeaderBinaryFields, source.innerHeaderBinaryFields)
    }

    func testNoUnknownInnerFieldsAreAddedWhenTheSourceHasNone() throws {
        let source = try B.read(Fixture.data("test.kdbx"), transformedKey: Fixture.testTransformedKey).header
        let file = try seal(xml, try Writer.prepareHeader(.reuse(source), requiredMinorVersion: 0))
        XCTAssertEqual(try innerHeaderItems(of: file, transformedKey: transformedKey).map(\.id), [1, 2, 0])
    }

    /// The protected values are masked against the prepared header's stream key.
    func testInnerStreamKeyOfThePreparedHeaderDecodesValues() throws {
        let header = try fresh()
        var writerStream = try KDBXInnerStream(streamID: header.innerStreamID, key: header.innerStreamKey)
        let masked = writerStream.apply(Data("secret".utf8)).base64EncodedString()
        let file = try seal(Data("<KeePassFile><Value Protected=\"True\">\(masked)</Value></KeePassFile>".utf8), header)
        let payload = try B.read(file, transformedKey: transformedKey)
        XCTAssertEqual(try KDBXInnerStreamTests.decodeProtectedValues(in: payload), ["secret"])
    }

    func testSealRejectsUnknownCipherAndPropagatesKDFErrors() throws {
        var header = try fresh()
        header.cipherID = Data(count: 16)
        assertThrows(KDBXCrypto.CryptoError.unsupportedCipher(Data(count: 16))) { try self.seal(self.xml, header) }

        struct Refused: Error, Equatable {}
        assertThrows(Refused()) { try Writer.seal(xml: self.xml, header: try self.fresh()) { _ in throw Refused() } }
    }

    func testSealWithAWrongSizedIVFails() throws {
        var header = try fresh()
        header.encryptionIV = Data(count: 12)
        assertThrows(KDBXCrypto.CryptoError.encryptionFailed) { try self.seal(self.xml, header) }
    }

    func testSealRealKDFRoundTrip() throws {
        let compositeKey = try KDBXCrypto.compositeKey(password: "pw", keyFileData: Data(repeating: 1, count: 32))
        let header = try fresh(kdf: TestKDF.cheapArgon2())
        let file = try Writer.seal(xml: xml, header: header) {
            try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: $0, policy: TestKDF.permissivePolicy)
        }
        XCTAssertEqual(try KDBXContainer.read(data: file, compositeKey: compositeKey, kdfPolicy: TestKDF.permissivePolicy).xml, xml)
    }

    /// A gzip payload over the read limit is refused before compressing, so
    /// the writer never produces a file it could not open.
    func testPayloadTooLarge() throws {
        let header = try fresh()
        let tooLarge = Data(count: KDBXContainer.maxDecompressedPayloadSize)
        assertThrows(Writer.WriteError.payloadTooLarge) { try self.seal(tooLarge, header) }
    }
}
