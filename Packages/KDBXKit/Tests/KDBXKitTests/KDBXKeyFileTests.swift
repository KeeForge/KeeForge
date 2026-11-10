import CryptoKit
import XCTest
@testable import KDBXKit

final class KDBXKeyFileTests: XCTestCase {
    /// The fixture key files all hold bytes 0x00...0x1f.
    private let expectedKey = Data((0..<32).map { UInt8($0) })
    private let upperHex = "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"

    private func keyFileXML(version: String, data: String, hash: String? = nil) -> Data {
        let hashAttribute = hash.map { " Hash=\"\($0)\"" } ?? ""
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <KeyFile>
          <Meta><Version>\(version)</Version></Meta>
          <Key><Data\(hashAttribute)>\(data)</Data></Key>
        </KeyFile>
        """.utf8)
    }

    // MARK: - Binary

    func testBinaryKeyFileIsTheKey() throws {
        XCTAssertEqual(try KDBXKeyFile.key(from: Fixture.data("demo-keyfile.key")), expectedKey)
        let raw = Data(repeating: 0xAB, count: 32)
        XCTAssertEqual(KDBXKeyFile.tryBinaryFormat(raw), raw)
        XCTAssertNil(KDBXKeyFile.tryBinaryFormat(Data(count: 31)))
        XCTAssertNil(KDBXKeyFile.tryBinaryFormat(Data(count: 33)))
    }

    // MARK: - Hex

    func testHexKeyFileDecodes() throws {
        XCTAssertEqual(try KDBXKeyFile.key(from: Fixture.data("test-hex.key")), expectedKey)
        XCTAssertEqual(KDBXKeyFile.tryHexFormat(Data(upperHex.lowercased().utf8)), expectedKey)
    }

    func testNonHexFallsThroughToTheHash() throws {
        let notHex = Data(String(repeating: "ZZ", count: 32).utf8)
        XCTAssertNil(KDBXKeyFile.tryHexFormat(notHex))
        XCTAssertEqual(try KDBXKeyFile.key(from: notHex), Data(SHA256.hash(data: notHex)))
    }

    func testHexRequiresExactly64ASCIIHexCharacters() {
        XCTAssertNil(KDBXKeyFile.tryHexFormat(Data(upperHex.dropLast().utf8)))
        XCTAssertNil(KDBXKeyFile.tryHexFormat(Data((upperHex.dropLast() + "\n").utf8)), "a newline is not a digit")
        XCTAssertNil(KDBXKeyFile.tryHexFormat(Data(repeating: 0xC1, count: 64)), "not ASCII")
    }

    // MARK: - XML

    func testXMLVersion1DecodesBase64() throws {
        XCTAssertEqual(try KDBXKeyFile.key(from: Fixture.data("test-v1.key")), expectedKey)
        XCTAssertEqual(
            try KDBXKeyFile.key(from: keyFileXML(version: "1.0", data: "  \(expectedKey.base64EncodedString())\n ")),
            expectedKey
        )
    }

    func testXMLVersion2DecodesHexAndChecksTheHash() throws {
        XCTAssertEqual(try KDBXKeyFile.key(from: Fixture.data("test-v2.keyx")), expectedKey)
        let spaced = "00010203 04050607\n08090A0B0C0D0E0F 101112131415161718191A1B1C1D1E1F"
        XCTAssertEqual(try KDBXKeyFile.key(from: keyFileXML(version: "2.0", data: spaced)), expectedKey, "the hash is optional")
        XCTAssertEqual(try KDBXKeyFile.key(from: keyFileXML(version: "2.0", data: upperHex, hash: "630dcd29")), expectedKey)
    }

    func testXMLVersion2RejectsAMismatchedOrMalformedHash() {
        for hash in ["DEADBEEF", "630DCD2", "XYZW"] {
            assertThrows(KDBXKeyFile.KeyFileError.xmlHashMismatch) {
                try KDBXKeyFile.key(from: self.keyFileXML(version: "2.0", data: self.upperHex, hash: hash))
            }
        }
    }

    func testXMLRejectsInvalidKeyData() throws {
        assertThrows(KDBXKeyFile.KeyFileError.xmlKeyDataInvalid) { try KDBXKeyFile.key(from: Fixture.data("invalid-xml.keyx")) }
        let invalid: [(String, String)] = [
            ("1.0", Data(count: 16).base64EncodedString()),
            ("1.0", "not base64!"),
            ("2.0", String(upperHex.dropLast(2))),
            ("2.0", String(upperHex.dropLast())),
            ("2.0", String(repeating: "GG", count: 32)),
        ]
        for (version, data) in invalid {
            assertThrows(KDBXKeyFile.KeyFileError.xmlKeyDataInvalid) {
                try KDBXKeyFile.key(from: self.keyFileXML(version: version, data: data))
            }
        }
    }

    /// The major version picks the format, as in KeePass; a missing version reads as 1.0.
    func testMajorVersionPicksTheFormat() throws {
        for version in ["", "1.0", "1.00", "1.1"] {
            XCTAssertEqual(try KDBXKeyFile.key(from: keyFileXML(version: version, data: expectedKey.base64EncodedString())), expectedKey, version)
        }
        for version in ["2.0", "2.1"] {
            XCTAssertEqual(try KDBXKeyFile.key(from: keyFileXML(version: version, data: upperHex)), expectedKey, version)
        }
    }

    func testUnknownMajorVersionsAreRejected() {
        for version in ["3.0", "0.9", "x"] {
            assertThrows(KDBXKeyFile.KeyFileError.xmlVersionUnsupported) {
                try KDBXKeyFile.key(from: self.keyFileXML(version: version, data: self.upperHex))
            }
        }
    }

    func testOnlyMetaVersionAndKeyDataCount() throws {
        let xml = Data("""
        <KeyFile>
          <Version>2.0</Version>
          <Data>\(upperHex)</Data>
          <Meta><Data>ignored</Data><Version>2.0</Version></Meta>
          <Key><Data>\(upperHex)</Data></Key>
        </KeyFile>
        """.utf8)
        XCTAssertEqual(try KDBXKeyFile.key(from: xml), expectedKey)
    }

    func testXMLWithoutKeyDataFallsBackToTheHash() throws {
        let xml = Data("<?xml version=\"1.0\"?><KeyFile><Meta><Version>2.0</Version></Meta></KeyFile>".utf8)
        XCTAssertNil(try KDBXKeyFile.tryXMLFormat(xml))
        XCTAssertEqual(try KDBXKeyFile.key(from: xml), Data(SHA256.hash(data: xml)))
    }

    func testMalformedXMLFallsBackToTheHash() throws {
        let xml = Data("<?xml version=\"1.0\"?><KeyFile><Key><Data>abc</Key>".utf8)
        XCTAssertNil(try KDBXKeyFile.tryXMLFormat(xml))
        XCTAssertEqual(try KDBXKeyFile.key(from: xml), Data(SHA256.hash(data: xml)))
    }

    func testNonXMLIsNotParsedAsXML() throws {
        XCTAssertNil(try KDBXKeyFile.tryXMLFormat(Data("plain text".utf8)))
        XCTAssertNil(try KDBXKeyFile.tryXMLFormat(Data([0xFF, 0xFE, 0x3C, 0x00])))
    }

    /// A multibyte character straddling byte 256 must not hide the XML marker.
    func testXMLDetectionSurvivesASplitMultibyteCharacter() throws {
        let prefix = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!-- "
        let padding = String(repeating: "a", count: 255 - prefix.utf8.count) + "é -->"
        let xml = Data((prefix + padding + """
        <KeyFile><Meta><Version>2.0</Version></Meta><Key><Data>\(upperHex)</Data></Key></KeyFile>
        """).utf8)
        XCTAssertEqual(xml[255], 0xC3, "the é starts at byte 255")
        XCTAssertEqual(try KDBXKeyFile.key(from: xml), expectedKey)
    }

    // MARK: - Fallback

    func testArbitraryFileIsHashed() throws {
        let data = try Fixture.data("test-arbitrary.key")
        XCTAssertEqual(try KDBXKeyFile.key(from: data), Data(SHA256.hash(data: data)))
        XCTAssertEqual(KDBXKeyFile.hashFallback(Data("x".utf8)).hex, "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
    }

    func testEmptyFileThrows() {
        assertThrows(KDBXKeyFile.KeyFileError.emptyKeyFile) { try KDBXKeyFile.key(from: Data()) }
    }

    func testSlicesAreAccepted() throws {
        XCTAssertEqual(try KDBXKeyFile.key(from: expectedKey.asSlice), expectedKey)
        XCTAssertEqual(try KDBXKeyFile.key(from: Data(upperHex.utf8).asSlice), expectedKey)
        XCTAssertEqual(try KDBXKeyFile.key(from: Fixture.data("test-v2.keyx").asSlice), expectedKey)
    }

    // MARK: - Composite key

    func testCompositeKeyWithKeyFile() throws {
        let keyFile = try Fixture.data("demo-keyfile.key")
        let expected = Data(SHA256.hash(data: Data(SHA256.hash(data: Data("demo".utf8))) + expectedKey))
        XCTAssertEqual(try KDBXCrypto.compositeKey(password: "demo", keyFileData: keyFile).bytes, expected)
        XCTAssertEqual(
            try KDBXCrypto.compositeKey(password: nil, keyFileData: keyFile).bytes,
            Data(SHA256.hash(data: expectedKey))
        )
        XCTAssertEqual(
            try KDBXCrypto.compositeKey(password: "", keyFileData: keyFile),
            try KDBXCrypto.compositeKey(password: nil, keyFileData: keyFile)
        )
    }

    func testCompositeKeyRejectsMalformedXMLKeyFilesInsteadOfDroppingThem() {
        for password in [nil, "password"] as [String?] {
            assertThrows(KDBXKeyFile.KeyFileError.xmlKeyDataInvalid) {
                try KDBXCrypto.compositeKey(password: password, keyFileData: self.keyFileXML(version: "1.0", data: "short"))
            }
            assertThrows(KDBXKeyFile.KeyFileError.xmlHashMismatch) {
                try KDBXCrypto.compositeKey(password: password, keyFileData: self.keyFileXML(version: "2.0", data: self.upperHex, hash: "DEADBEEF"))
            }
        }
    }

    // MARK: - Generation

    func testGeneratedKeyFileIsXMLv2WithGroupedHexKeyAndMatchingHash() throws {
        let file = try KDBXKeyFile.generate()
        let text = try XCTUnwrap(String(data: file, encoding: .utf8))
        let lines = text.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, #"<?xml version="1.0" encoding="utf-8"?>"#)
        XCTAssertTrue(text.contains("<Version>2.0</Version>"))
        let keyLines = lines.filter {
            $0.range(of: #"^\t\t\t[0-9A-F]{8}( [0-9A-F]{8}){3}$"#, options: .regularExpression) != nil
        }
        XCTAssertEqual(keyLines.count, 2)
        let key = Data(hex: keyLines.joined().filter(\.isHexDigit))
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(try KDBXKeyFile.tryXMLFormat(file), key)
        XCTAssertEqual(try KDBXKeyFile.key(from: file), key)

        let hashRange = try XCTUnwrap(text.range(of: #"(?<=Hash=")[0-9A-F]{8}(?=")"#, options: .regularExpression))
        let expectedHash = SHA256.hash(data: key).prefix(4).map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(String(text[hashRange]), expectedHash)
        XCTAssertEqual(KDBXKeyFile.generatedFileExtension, "keyx")
    }

    func testGenerationFailsWhenNoRandomBytesAreAvailable() {
        assertThrows(KDBXContainerWriter.WriteError.randomGenerationFailed(errSecParam)) {
            try KDBXKeyFile.generate { _ in errSecParam }
        }
    }

    func testEachGeneratedKeyFileHasADifferentKey() throws {
        let keys = try (0..<3).map { _ in try KDBXKeyFile.key(from: KDBXKeyFile.generate()) }

        XCTAssertEqual(Set(keys).count, 3)
    }
}
