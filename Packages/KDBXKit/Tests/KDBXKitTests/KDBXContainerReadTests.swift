import CryptoKit
import XCTest
@testable import KDBXKit

final class KDBXContainerReadTests: XCTestCase {
    private typealias B = KDBX4Builder

    // MARK: - Fixtures

    func testReadsTheKDBX4Fixture() throws {
        let data = try Fixture.data("test.kdbx")
        var seenParameters: KDBXVariantMap?
        let payload = try KDBXContainer.read(data: data) { parameters in
            seenParameters = parameters
            return Fixture.testTransformedKey
        }
        let header = payload.header
        XCTAssertEqual(seenParameters, header.kdfParameters)
        XCTAssertEqual(header.formatVersion, .kdbx4(minor: 0))
        XCTAssertEqual(header.cipher, .aes256CBC)
        XCTAssertEqual(header.compression, .gzip)
        XCTAssertEqual(header.masterSeed.count, 32)
        XCTAssertEqual(header.encryptionIV.count, 16)
        XCTAssertEqual(header.keyDerivation?.algorithm, .argon2d)
        guard case .argon2(let argon2)? = header.keyDerivation else { return XCTFail("not Argon2") }
        XCTAssertEqual(argon2.iterations, 14)
        XCTAssertEqual(argon2.memoryBytes, 64 * 1024 * 1024)
        XCTAssertEqual(argon2.parallelism, 2)
        XCTAssertEqual(header.innerStreamID, KDBXInnerStream.Algorithm.chaCha20.rawValue)
        XCTAssertEqual(header.innerStreamKey.count, 64)
        XCTAssertEqual(header.headerData, data.prefix(253))
        XCTAssertTrue(header.unknownOuterHeaderFields.isEmpty)
        XCTAssertTrue(header.unknownInnerHeaderFields.isEmpty)

        XCTAssertTrue(isKeePassXML(payload.xml), String(decoding: payload.xml.prefix(80), as: UTF8.self))
        XCTAssertTrue(try KDBXInnerStreamTests.decodeProtectedValues(in: payload).contains("twitterpass123"))
    }

    func testReadHeaderWithoutCredentialsMatchesTheDecryptedHeaderOuterFields() throws {
        let data = try Fixture.data("test.kdbx")
        let plain = try KDBXContainer.readHeader(from: data)
        var full = try B.read(data, transformedKey: Fixture.testTransformedKey).header
        XCTAssertTrue(plain.innerStreamKey.isEmpty)
        XCTAssertEqual(plain.innerStreamID, 0)
        full.innerStreamID = 0
        full.innerStreamKey = Data()
        full.innerHeaderBinaryFields = []
        XCTAssertEqual(plain, full)

        XCTAssertEqual(try KDBXContainer.readHeader(from: data.prefix(253)), plain, "a header-sized prefix is enough")
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try KDBXContainer.readHeader(from: data.prefix(252)) }
    }

    func testReadsTheKeyFileFixture() throws {
        let payload = try B.read(Fixture.data("demo-keyfile.kdbx"), transformedKey: Fixture.keyFileTransformedKey)
        XCTAssertTrue(try KDBXInnerStreamTests.decodeProtectedValues(in: payload).contains("keyfilepass123"))
    }

    func testReadsForeignChaCha20AndTwofishFixtures() throws {
        let chaCha = try B.read(Fixture.data("foreign-chacha20.kdbx"), transformedKey: Fixture.chaCha20TransformedKey)
        XCTAssertEqual(chaCha.header.cipher, .chaCha20)
        XCTAssertEqual(chaCha.header.encryptionIV.count, 12)
        XCTAssertTrue(isKeePassXML(chaCha.xml), String(decoding: chaCha.xml.prefix(80), as: UTF8.self))

        let twofish = try B.read(Fixture.data("foreign-twofish.kdbx"), transformedKey: Fixture.twofishTransformedKey)
        XCTAssertEqual(twofish.header.cipher, .twofish256CBC)
        XCTAssertTrue(isKeePassXML(twofish.xml), String(decoding: twofish.xml.prefix(80), as: UTF8.self))
    }

    func testKeepsUnknownInnerHeaderFieldsAndTheBinaryPool() throws {
        let payload = try B.read(Fixture.data("unknown-inner-header.kdbx"), transformedKey: Fixture.unknownInnerHeaderTransformedKey)
        XCTAssertEqual(payload.header.unknownInnerHeaderFields, [
            .init(id: 0x21, data: Data("mid-pool-unknown-field".utf8)),
            .init(id: 0x7F, data: Data("kdbx-format-hardening-fixture:unknown-field-0x7f-marker".utf8)),
            .init(id: 0x10, data: Data()),
        ])
        XCTAssertEqual(payload.header.innerHeaderBinaryFields.count, 2)
        XCTAssertTrue(payload.header.innerHeaderBinaryFields.allSatisfy { !$0.isEmpty })
    }

    /// The composite-key entry point runs the KDF the header names.
    func testReadWithCompositeKeyRunsTheKDF() throws {
        let fixture = try Fixture.data("challenge-response-aeskdf.kdbx")
        let header = try KDBXContainer.readHeader(from: fixture)
        XCTAssertEqual(header.keyDerivation?.algorithm, .aesKDF)

        let compositeKey = KDBXCrypto.compositeKey(password: "x")
        let file = try KDBXContainerWriter.seal(
            xml: B.xml,
            header: KDBXContainerWriter.prepareHeader(
                .fresh(.init(cipher: .aes256CBC, kdfParameters: TestKDF.cheapArgon2())),
                requiredMinorVersion: 0
            )
        ) { parameters in
            try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: parameters, policy: TestKDF.permissivePolicy)
        }
        let payload = try KDBXContainer.read(data: file, compositeKey: compositeKey, kdfPolicy: TestKDF.permissivePolicy)
        XCTAssertEqual(payload.xml, B.xml)

        assertThrows(KDBXCrypto.CryptoError.hmacMismatch) {
            try KDBXContainer.read(data: file, compositeKey: KDBXCrypto.compositeKey(password: "y"), kdfPolicy: TestKDF.permissivePolicy)
        }
        let strict = KDFExecutionPolicy(maxPeakMemoryBytes: 1024, maxTotalWorkBytes: .max, maxParallelism: 1)
        assertThrows(KDBXContainer.ParseError.kdfResourceLimitExceeded(iterations: 1, memoryBytes: 1 << 20, parallelism: 1)) {
            try KDBXContainer.read(data: file, compositeKey: compositeKey, kdfPolicy: strict)
        }
    }

    func testWrongTransformedKeyFailsTheHeaderHMAC() throws {
        assertThrows(KDBXCrypto.CryptoError.hmacMismatch) {
            try B.read(Fixture.data("test.kdbx"), transformedKey: Data(count: 32))
        }
    }

    func testTransformedKeyErrorsPropagate() throws {
        struct Refused: Error, Equatable {}
        assertThrows(Refused()) {
            try KDBXContainer.read(data: Fixture.data("test.kdbx")) { _ in throw Refused() }
        }
    }

    // MARK: - Version and signature

    func testParsesFileVersions() throws {
        XCTAssertEqual(try KDBXContainer.parseFileVersion(from: Fixture.data("test.kdbx")), .kdbx4(minor: 0))
        XCTAssertEqual(try KDBXContainer.parseFileVersion(from: Fixture.data("legacy-kdbx31.kdbx")), .kdbx3_1)
        XCTAssertEqual(try KDBXContainer.parseFileVersion(from: B.versionPrefix(minor: 1).asSlice), .kdbx4(minor: 1))
        XCTAssertEqual(try KDBXContainer.parseFileVersion(from: B.versionPrefix(minor: 9)), .kdbx4(minor: 9))
    }

    func testFileVersionProperties() {
        let versions: [KDBXContainer.FileVersion] = [.kdbx3_1, .kdbx4(minor: 0), .kdbx4(minor: 1)]
        XCTAssertEqual(versions.map(\.majorVersion), [3, 4, 4])
        XCTAssertEqual(versions.map(\.minorVersion), [1, 0, 1])
        XCTAssertEqual(versions.map(\.requiresReadOnlyMode), [true, false, false])
    }

    func testRejectsBadSignaturesAndVersions() {
        var badFirst = B.versionPrefix()
        badFirst[0] ^= 1
        var badSecond = B.versionPrefix()
        badSecond[4] ^= 1
        for data in [badFirst, badSecond, Data("not a database at all".utf8)] {
            assertThrows(KDBXContainer.ParseError.invalidSignature) { try KDBXContainer.parseFileVersion(from: data) }
            assertThrows(KDBXContainer.ParseError.invalidSignature) { try KDBXContainer.readHeader(from: data) }
            assertThrows(KDBXContainer.ParseError.invalidSignature) { try B.read(data) }
        }
        let unsupported: [(UInt16, UInt16)] = [(3, 0), (3, 2), (2, 1), (5, 0), (1, 0)]
        for (major, minor) in unsupported {
            assertThrows(KDBXContainer.ParseError.unsupportedVersion(major)) {
                try KDBXContainer.parseFileVersion(from: B.versionPrefix(minor: minor, major: major))
            }
            assertThrows(KDBXContainer.ParseError.unsupportedVersion(major)) {
                try B.read(B.versionPrefix(minor: minor, major: major) + Data(count: 100))
            }
        }
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try KDBXContainer.parseFileVersion(from: Data()) }
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try KDBXContainer.parseFileVersion(from: B.versionPrefix().prefix(11)) }
    }

    // MARK: - Outer header

    func testReadHeaderKeepsUnknownOuterFieldsAndLongIntegerFields() throws {
        let fields: [B.Field] = [
            (2, KDBXOuterCipher.twofish256CBC.uuid),
            (3, Data([1, 0, 0, 0, 0xAA, 0xBB])),
            (4, B.masterSeed),
            (0x0C, Data("public custom data".utf8)),
            (7, B.aesIV),
            (11, TestKDF.cheapArgon2().serialized()),
            (0x30, Data()),
        ]
        let headerBytes = B.outerHeader(minor: 1, fields: fields)
        let header = try KDBXContainer.readHeader(from: (headerBytes + Data(count: 64)).asSlice)
        XCTAssertEqual(header, KDBXContainer.Header(
            formatVersion: .kdbx4(minor: 1),
            cipherID: KDBXOuterCipher.twofish256CBC.uuid,
            compressionFlags: 1,
            masterSeed: B.masterSeed,
            encryptionIV: B.aesIV,
            kdfParameters: TestKDF.cheapArgon2(),
            unknownOuterHeaderFields: [.init(id: 0x0C, data: Data("public custom data".utf8)), .init(id: 0x30, data: Data())],
            headerData: headerBytes
        ))
    }

    func testUnknownHeaderValuesSurviveAndReportAsNil() throws {
        let fields: [B.Field] = [(2, Data(count: 16)), (3, Data(littleEndian: UInt32(7))), (11, KDBXVariantMap(["$UUID": .bytes(Data(count: 16))]).serialized())]
        let header = try KDBXContainer.readHeader(from: B.outerHeader(fields: fields))
        XCTAssertEqual(header.cipherID, Data(count: 16))
        XCTAssertNil(header.cipher)
        XCTAssertEqual(header.compressionFlags, 7)
        XCTAssertNil(header.compression)
        XCTAssertNil(header.keyDerivation)
    }

    func testHeaderWithoutFieldsHasDefaults() throws {
        let header = try KDBXContainer.readHeader(from: B.outerHeader(fields: []))
        XCTAssertEqual(header.cipherID, Data())
        XCTAssertEqual(header.kdfParameters, [:])
        XCTAssertEqual(KDBXContainer.Header(), KDBXContainer.Header(formatVersion: .kdbx4(minor: 0)))
    }

    func testOuterHeaderErrors() {
        assertThrows(KDBXContainer.ParseError.truncatedFile) {
            try KDBXContainer.readHeader(from: B.outerHeader(fields: [(3, Data([1, 0]))]))
        }
        assertThrows(KDBXContainer.ParseError.malformedVariantMap) {
            try KDBXContainer.readHeader(from: B.outerHeader(fields: [(11, Data([0x00, 0x02]))]))
        }
    }

    func testTruncatedHeaderAtEveryOffset() throws {
        let header = B.outerHeader()
        for length in 0..<header.count {
            assertThrows(KDBXContainer.ParseError.truncatedFile) { try KDBXContainer.readHeader(from: header.prefix(length)) }
        }
    }

    // MARK: - Header integrity

    func testHeaderHashAndHMACMismatches() throws {
        let file = try B.file(plaintextPayload: Data())
        let headerLength = B.outerHeader().count

        var badHash = file
        badHash[headerLength] ^= 1
        assertThrows(KDBXContainer.ParseError.headerHashMismatch) { try B.read(badHash) }

        var badHMAC = file
        badHMAC[headerLength + 32] ^= 1
        assertThrows(KDBXCrypto.CryptoError.hmacMismatch) { try B.read(badHMAC) }

        // A header edited without updating its hash.
        var edited = file
        edited[20] ^= 1
        assertThrows(KDBXContainer.ParseError.headerHashMismatch) { try B.read(edited) }
    }

    /// Every truncation fails cleanly, whatever structure it cuts.
    func testTruncationAtEveryOffsetFails() throws {
        let file = try B.file(plaintextPayload: B.innerHeader() + B.xml)
        XCTAssertEqual(try B.read(file).xml, B.xml)
        for length in 0..<file.count {
            XCTAssertThrowsError(try B.read(file.prefix(length)), "length \(length)") { error in
                XCTAssertTrue(
                    [.truncatedFile, .invalidBlockHMAC].contains(error as? KDBXContainer.ParseError),
                    "length \(length): \(error)"
                )
            }
        }
    }

    // MARK: - Blocks

    func testBlockHMACMismatchAndNegativeSize() throws {
        let file = try B.file(plaintextPayload: B.innerHeader() + B.xml)
        let blocksStart = B.outerHeader().count + 64

        var badHMAC = file
        badHMAC[blocksStart] ^= 1
        assertThrows(KDBXContainer.ParseError.invalidBlockHMAC) { try B.read(badHMAC) }

        var badData = file
        badData[blocksStart + 40] ^= 1
        assertThrows(KDBXContainer.ParseError.invalidBlockHMAC) { try B.read(badData) }

        var negative = file
        negative.replaceSubrange((blocksStart + 32)..<(blocksStart + 36), with: Data(littleEndian: Int32(-1)))
        assertThrows(KDBXContainer.ParseError.truncatedFile) { try B.read(negative) }
    }

    /// Blocks are bound to their index: swapping two fails.
    func testReorderedBlocksFail() throws {
        let keys = B.masterKeys()
        let encrypted = try KDBXOuterCipher.aes256CBC.encrypt(data: B.innerHeader() + B.xml, key: keys.cipherKey, iv: B.aesIV)
        let framed = B.blocks(encrypted, base: keys.hmacBase, blockSize: 32)
        let header = B.outerHeader()
        let prefix = header + Data(SHA256.hash(data: header)) + B.hmac(header, key: B.blockKey(index: .max, base: keys.hmacBase))
        XCTAssertEqual(try B.read(prefix + framed).xml, B.xml, "small blocks read")

        let blockLength = 32 + 4 + 32
        let swapped = framed.subdata(in: blockLength..<(2 * blockLength))
            + framed.subdata(in: 0..<blockLength)
            + framed.subdata(in: (2 * blockLength)..<framed.count)
        assertThrows(KDBXContainer.ParseError.invalidBlockHMAC) { try B.read(prefix + swapped) }
    }

    func testBlockFramingMatchesAnIndependentHMAC() throws {
        let base = Data(repeating: 3, count: 64)
        let block = Data("block".utf8)
        let expected = B.hmac(Data(littleEndian: UInt64(5)) + Data(littleEndian: Int32(5)) + block, key: B.blockKey(index: 5, base: base))
        XCTAssertEqual(KDBXContainer.blockHMAC(blockIndex: 5, block: block, baseKey: base), expected)
        XCTAssertEqual(KDBXContainer.blockHMACKey(blockIndex: .max, baseKey: base), B.blockKey(index: .max, base: base))
    }

    func testMasterKeysMatchTheKDBXDefinition() {
        var keys = KDBXContainer.MasterKeys(masterSeed: B.masterSeed, transformedKey: B.transformedKey)
        let expected = B.masterKeys()
        XCTAssertEqual(keys.masterKey, expected.cipherKey)
        XCTAssertEqual(keys.hmacBaseKey, expected.hmacBase)
        XCTAssertEqual(keys.headerHMAC(for: Data("h".utf8)), B.hmac(Data("h".utf8), key: B.blockKey(index: .max, base: expected.hmacBase)))
        keys.wipe()
        XCTAssertEqual(keys.masterKey, Data(count: 32))
        XCTAssertEqual(keys.hmacBaseKey, Data(count: 64))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(KDBXContainer.constantTimeEqual(Data([1, 2]), Data([1, 2])))
        XCTAssertTrue(KDBXContainer.constantTimeEqual(Data(), Data()))
        XCTAssertFalse(KDBXContainer.constantTimeEqual(Data([1, 2]), Data([1, 3])))
        XCTAssertFalse(KDBXContainer.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])))
    }

    // MARK: - Payload

    func testUnknownCipherFailsAfterTheHeaderChecks() throws {
        let unknown = Data(repeating: 0xCD, count: 16)
        var fields = B.standardOuterFields()
        fields[0] = (2, unknown)
        let file = try B.file(header: B.outerHeader(fields: fields), plaintextPayload: B.innerHeader() + B.xml)
        assertThrows(KDBXCrypto.CryptoError.unsupportedCipher(unknown)) { try B.read(file) }
    }

    func testPayloadThatDoesNotDecryptFails() throws {
        let keys = B.masterKeys()
        let header = B.outerHeader()
        let file = header + Data(SHA256.hash(data: header)) + B.hmac(header, key: B.blockKey(index: .max, base: keys.hmacBase))
            + B.blocks(Data(count: 17), base: keys.hmacBase)
        assertThrows(KDBXCrypto.CryptoError.decryptionFailed) { try B.read(file) }
    }

    func testEveryCipherReads() throws {
        for cipher in KDBXOuterCipher.allCases {
            let iv = Data(repeating: 0x22, count: cipher.encryptionIVLength)
            let header = B.outerHeader(fields: B.standardOuterFields(cipher: cipher, compression: 0, iv: iv))
            let file = try B.file(header: header, plaintextPayload: B.innerHeader() + B.xml, cipher: cipher, iv: iv)
            XCTAssertEqual(try B.read(file).xml, B.xml, "\(cipher)")
        }
    }

    func testStandardCompressedPayload() throws {
        let binary = Data([0x01]) + Data("attachment".utf8)
        let inner = B.innerHeader(extra: [(3, binary), (0x40, Data([1, 2])), (3, Data([0x00]))])
        let payload = try B.read(B.file(plaintextPayload: Gzip.compress(inner + B.xml)))
        XCTAssertEqual(payload.xml, B.xml)
        XCTAssertEqual(payload.header.innerStreamID, 3)
        XCTAssertEqual(payload.header.innerStreamKey, Data(repeating: 0x77, count: 64))
        XCTAssertEqual(payload.header.innerHeaderBinaryFields, [binary, Data([0x00])])
        XCTAssertEqual(payload.header.unknownInnerHeaderFields, [.init(id: 0x40, data: Data([1, 2]))])
    }

    func testUncompressedPayload() throws {
        let header = B.outerHeader(fields: B.standardOuterFields(compression: 0))
        let payload = try B.read(B.file(header: header, plaintextPayload: B.innerHeader() + B.xml))
        XCTAssertEqual(payload.xml, B.xml)
        XCTAssertEqual(payload.header.compression, KDBXContainer.Compression.none)
    }

    /// Uncompressed flag, so gzip-looking XML is returned as stored.
    func testUncompressedPayloadIsNotDecompressed() throws {
        let header = B.outerHeader(fields: B.standardOuterFields(compression: 0))
        let gzipped = try Gzip.compress(B.xml)
        XCTAssertEqual(try B.read(B.file(header: header, plaintextPayload: B.innerHeader() + gzipped)).xml, gzipped)
    }

    // MARK: - Compatibility tolerances

    func testInnerHeaderFollowedByCompressedXML() throws {
        let payload = try B.read(B.file(plaintextPayload: B.innerHeader() + Gzip.compress(B.xml)))
        XCTAssertEqual(payload.xml, B.xml)
        XCTAssertEqual(payload.header.innerStreamID, 3)
    }

    func testPlainXMLDespiteTheGzipFlag() throws {
        for xml in [B.xml, Data([0xEF, 0xBB, 0xBF]) + B.xml, Data("<KeePassFile></KeePassFile>".utf8)] {
            XCTAssertEqual(try B.read(B.file(plaintextPayload: B.innerHeader() + xml)).xml, xml)
        }
    }

    func testGzipFlagWithNeitherGzipNorXMLFails() throws {
        for tail in [Data("garbage".utf8), Data([0xEF, 0xBB, 0xBF]) + Data("garbage".utf8), Data()] {
            assertThrows(KDBXCrypto.CryptoError.decompressionFailed) {
                try B.read(B.file(plaintextPayload: B.innerHeader() + tail))
            }
        }
    }

    /// Over the limit is its own error in every compressed layout, never
    /// read as plain or damaged data.
    func testPayloadOverTheDecompressionLimitIsReportedAsTooLarge() throws {
        let oversized = Data(count: KDBXContainer.maxDecompressedPayloadSize + 1)
        for plaintext in [try Gzip.compress(B.innerHeader() + oversized), B.innerHeader() + (try Gzip.compress(oversized))] {
            assertThrows(KDBXContainer.ParseError.decompressedPayloadTooLarge) {
                try B.read(B.file(plaintextPayload: plaintext))
            }
        }
    }

    func testInnerHeaderWithoutTerminator() throws {
        let header = B.outerHeader(fields: B.standardOuterFields(compression: 0))
        let inner = B.innerHeader(extra: [(3, Data([1, 2, 3]))], terminated: false)
        let payload = try B.read(B.file(header: header, plaintextPayload: inner))
        XCTAssertEqual(payload.xml, Data())
        XCTAssertEqual(payload.header.innerHeaderBinaryFields, [Data([1, 2, 3])])
        XCTAssertEqual(payload.header.innerStreamKey.count, 64)
    }

    func testInnerHeaderTerminatorWithAValue() throws {
        let header = B.outerHeader(fields: B.standardOuterFields(compression: 0))
        let inner = B.fields([(1, Data(littleEndian: UInt32(2))), (2, Data([9])), (0, Data([0xAA, 0xBB]))])
        let payload = try B.read(B.file(header: header, plaintextPayload: inner + B.xml))
        XCTAssertEqual(payload.xml, B.xml)
        XCTAssertEqual(payload.header.innerStreamID, 2)
    }

    func testTruncatedInnerHeaderFails() throws {
        let header = B.outerHeader(fields: B.standardOuterFields(compression: 0))
        let inner = B.innerHeader()
        for cut in [1, 3, 5, 7, 12, inner.count - 3] {
            assertThrows(KDBXContainer.ParseError.truncatedFile) {
                try B.read(B.file(header: header, plaintextPayload: inner.prefix(cut)))
            }
        }
        assertThrows(KDBXContainer.ParseError.truncatedFile) {
            try B.read(B.file(header: header, plaintextPayload: B.fields([(1, Data([1, 0]))])))
        }
    }

    // MARK: - Slices

    func testPublicEntryPointsAcceptSlices() throws {
        let file = try Fixture.data("test.kdbx")
        XCTAssertEqual(try KDBXContainer.parseFileVersion(from: file.asSlice), .kdbx4(minor: 0))
        XCTAssertEqual(try KDBXContainer.readHeader(from: file.asSlice), try KDBXContainer.readHeader(from: file))
        XCTAssertEqual(
            try B.read(file.asSlice, transformedKey: Fixture.testTransformedKey),
            try B.read(file, transformedKey: Fixture.testTransformedKey)
        )
        let legacy = try Fixture.data("legacy-kdbx31.kdbx")
        XCTAssertEqual(try KDBXContainer.readHeader(from: legacy.asSlice), try KDBXContainer.readHeader(from: legacy))
        XCTAssertEqual(
            try B.read(legacy.asSlice, transformedKey: Fixture.legacyTransformedKey).xml,
            try B.read(legacy, transformedKey: Fixture.legacyTransformedKey).xml
        )
    }

    func testPayloadInit() {
        let payload = KDBXContainer.Payload(header: .init(), xml: Data([1]))
        XCTAssertEqual(payload.xml, Data([1]))
        XCTAssertEqual(KDBXContainer.Compression.allCases, [.none, .gzip])
    }
}
