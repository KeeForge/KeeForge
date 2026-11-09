import CryptoKit
import XCTest
@testable import KDBXKit

/// KDBX 3.1, read through the same API as KDBX 4.
final class KDBXContainerLegacyReadTests: XCTestCase {
    private typealias B = KDBX4Builder
    private typealias L = KDBX3Builder

    private let xml = KDBX4Builder.xml

    // MARK: - Fixture

    func testReadsTheKDBX31FixtureWithItsPassword() throws {
        let data = try Fixture.data("legacy-kdbx31.kdbx")
        let payload = try KDBXContainer.read(
            data: data,
            compositeKey: KDBXCrypto.compositeKey(password: Fixture.legacyPassword),
            kdfPolicy: TestKDF.permissivePolicy
        )
        let header = payload.header
        XCTAssertEqual(header.formatVersion, .kdbx3_1)
        XCTAssertTrue(header.formatVersion.requiresReadOnlyMode)
        XCTAssertEqual(header.cipher, .aes256CBC)
        XCTAssertEqual(header.compression, .gzip)
        XCTAssertEqual(header.keyDerivation, .aesKDF(rounds: 1_000_000, seed: header.kdfParameters.bytes("S")))
        XCTAssertEqual(header.kdfParameters.bytes("S")?.count, 32)
        XCTAssertEqual(header.innerStreamID, KDBXInnerStream.Algorithm.salsa20.rawValue)
        XCTAssertEqual(header.innerStreamKey.count, 32)
        XCTAssertEqual(header.headerData, data.prefix(222))
        XCTAssertTrue(header.innerHeaderBinaryFields.isEmpty)
        XCTAssertTrue(payload.xml.starts(with: Data("<?xml".utf8)))
        XCTAssertEqual(payload.xml.count, 11_473)
    }

    func testReadHeaderMatchesTheDecryptedHeader() throws {
        let data = try Fixture.data("legacy-kdbx31.kdbx")
        XCTAssertEqual(
            try KDBXContainer.readHeader(from: data),
            try B.read(data, transformedKey: Fixture.legacyTransformedKey).header
        )
    }

    func testWrongKeyFailsTheStreamStartBytes() throws {
        let data = try Fixture.data("legacy-kdbx31.kdbx")
        // Most wrong keys fail the padding, some decrypt to garbage; both read the same.
        for byte in UInt8(0)..<8 {
            assertThrows(KDBXContainer.ParseError.invalidStreamStartBytes) {
                try B.read(data, transformedKey: Data(repeating: byte, count: 32))
            }
        }
    }

    /// The fixture re-encrypted with Twofish, the other KDBX 3.1 cipher.
    func testReadsTwofishKDBX31() throws {
        let data = try Fixture.data("legacy-kdbx31.kdbx")
        let header = try KDBXContainer.readHeader(from: data)
        let keys = KDBXContainer.MasterKeys(masterSeed: header.masterSeed, transformedKey: Fixture.legacyTransformedKey)
        let decrypted = try KDBXCrypto.decryptAES256CBC(data: data.dropFirst(header.headerData.count), key: keys.masterKey, iv: header.encryptionIV)
        var converted = header.headerData
        let cipherOffset = try XCTUnwrap(converted.range(of: KDBXOuterCipher.aes256CBC.uuid)).lowerBound
        converted.replaceSubrange(cipherOffset..<(cipherOffset + 16), with: KDBXOuterCipher.twofish256CBC.uuid)
        converted += try KDBXCrypto.encryptTwofish256CBC(data: decrypted, key: keys.masterKey, iv: header.encryptionIV)

        let payload = try B.read(converted, transformedKey: Fixture.legacyTransformedKey)
        XCTAssertEqual(payload.header.cipher, .twofish256CBC)
        XCTAssertTrue(try KDBXInnerStreamTests.decodeProtectedValues(in: payload).contains("tw1tterP@ss!"))
    }

    func testCorruptedHashedBlockFails() throws {
        let data = try Fixture.data("legacy-kdbx31.kdbx")
        let header = try KDBXContainer.readHeader(from: data)
        let keys = KDBXContainer.MasterKeys(masterSeed: header.masterSeed, transformedKey: Fixture.legacyTransformedKey)
        var decrypted = try KDBXCrypto.decryptAES256CBC(data: data.dropFirst(header.headerData.count), key: keys.masterKey, iv: header.encryptionIV)
        decrypted[32 + 4 + 32 + 4] ^= 1
        let corrupted = header.headerData + (try KDBXCrypto.encryptAES256CBC(data: decrypted, key: keys.masterKey, iv: header.encryptionIV))
        assertThrows(KDBXContainer.ParseError.invalidLegacyBlockHash) {
            try B.read(corrupted, transformedKey: Fixture.legacyTransformedKey)
        }
    }

    // MARK: - Built files

    func testReadsUncompressedAndCompressedPayloads() throws {
        let plain = try B.read(L.file(decryptedPayload: L.startBytes + L.blockStream(xml)))
        XCTAssertEqual(plain.xml, xml)
        XCTAssertEqual(plain.header.innerStreamKey, Data(repeating: 0x44, count: 32))
        XCTAssertEqual(plain.header.keyDerivation, .aesKDF(rounds: 1, seed: Data(repeating: 0x33, count: 32)))

        let gzip = try B.read(L.file(header: L.header(compression: 1), decryptedPayload: L.startBytes + L.blockStream(Gzip.compress(xml))))
        XCTAssertEqual(gzip.xml, xml)
    }

    func testReadsSeveralBlocks() throws {
        let stream = L.hashedBlock(index: 0, Data("<?xml ".utf8))
            + L.hashedBlock(index: 1, Data("version".utf8))
            + L.hashedBlock(index: 2, Data())
        XCTAssertEqual(try B.read(L.file(decryptedPayload: L.startBytes + stream)).xml, Data("<?xml version".utf8))
    }

    func testSkipsUnknownHeaderFieldsAndReadsLongIntegers() throws {
        let header = L.header(extra: [(0x20, Data([1, 2, 3])), (0x0B, Data())])
        XCTAssertEqual(try B.read(L.file(header: header, decryptedPayload: L.startBytes + L.blockStream(xml))).xml, xml)

        let fields: [B.Field] = [(6, Data(littleEndian: UInt64(9)) + Data([0xFF])), (10, Data([0, 0, 0, 0, 7])), (0, Data())]
        let parsed = try KDBXContainer.readHeader(from: B.versionPrefix(minor: 1, major: 3) + B.fields(fields, sizeWidth: 2))
        XCTAssertEqual(parsed.keyDerivation, .aesKDF(rounds: 9, seed: Data()))
        XCTAssertEqual(parsed.innerStreamID, 0)
    }

    func testRejectsUnreadableInnerStreamsBeforeTheKDF() throws {
        for streamID: UInt32 in [1, 4, 0xFFFF_FFFF] {
            let file = try L.file(header: L.header(streamID: streamID), decryptedPayload: L.startBytes + L.blockStream(xml))
            assertThrows(KDBXContainer.ParseError.unsupportedProtectedFieldStream(streamID)) {
                try KDBXContainer.read(data: file) { _ in
                    XCTFail("KDF ran")
                    return B.transformedKey
                }
            }
        }
        XCTAssertNoThrow(try B.read(L.file(header: L.header(streamID: 0), decryptedPayload: L.startBytes + L.blockStream(xml))))
    }

    func testRejectsChaCha20AndUnknownCiphers() throws {
        for cipher in [KDBXOuterCipher.chaCha20.uuid, Data(count: 16), Data()] {
            let file = try L.file(header: L.header(cipher: cipher), decryptedPayload: L.startBytes + L.blockStream(xml))
            assertThrows(KDBXCrypto.CryptoError.unsupportedCipher(cipher)) { try B.read(file) }
        }
    }

    func testStartBytesMismatch() throws {
        var other = L.startBytes
        other[31] ^= 1
        let file = try L.file(header: L.header(startBytes: other), decryptedPayload: L.startBytes + L.blockStream(xml))
        assertThrows(KDBXContainer.ParseError.invalidStreamStartBytes) { try B.read(file) }
    }

    func testPayloadShorterThanTheStartBytes() throws {
        let file = try L.file(header: L.header(startBytes: Data(count: 64)), decryptedPayload: Data(count: 10))
        assertThrows(KDBXContainer.ParseError.invalidStreamStartBytes) { try B.read(file) }
    }

    func testHashedBlockErrors() throws {
        let block = Data("<?xml".utf8)
        let cases: [(Data, KDBXContainer.ParseError)] = [
            (L.hashedBlock(index: 1, block), .invalidLegacyBlockHash),
            (L.hashedBlock(index: 0, block) + L.hashedBlock(index: 0, Data()), .invalidLegacyBlockHash),
            (L.hashedBlock(index: 0, block, hash: Data(count: 32)), .invalidLegacyBlockHash),
            (L.hashedBlock(index: 0, Data(), hash: Data(repeating: 1, count: 32)), .invalidLegacyBlockHash),
            (L.hashedBlock(index: 0, Data(), size: -1), .truncatedFile),
            (L.hashedBlock(index: 0, block), .truncatedFile),
            (L.hashedBlock(index: 0, block, size: 100), .truncatedFile),
            (Data(), .truncatedFile),
        ]
        for (stream, expected) in cases {
            assertThrows(expected) { try B.read(L.file(decryptedPayload: L.startBytes + stream)) }
        }
    }

    func testCompressedFlagWithUncompressedBlocksFails() throws {
        let file = try L.file(header: L.header(compression: 1), decryptedPayload: L.startBytes + L.blockStream(xml))
        assertThrows(KDBXCrypto.CryptoError.decompressionFailed) { try B.read(file) }
    }

    func testTruncatedHeaderAtEveryOffset() {
        let header = L.header()
        for length in 0..<header.count {
            assertThrows(KDBXContainer.ParseError.truncatedFile) { try KDBXContainer.readHeader(from: header.prefix(length)) }
            assertThrows(KDBXContainer.ParseError.truncatedFile) { try B.read(header.prefix(length)) }
        }
    }
}
