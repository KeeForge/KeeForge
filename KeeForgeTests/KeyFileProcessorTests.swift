import CryptoKit
import XCTest
@testable import KeeForge

final class KeyFileProcessorTests: XCTestCase {
    // The test key files all use bytes(range(32)) = 0x00..0x1f as the key
    private let expectedKeyHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    private var expectedKey: Data {
        dataFromHex(expectedKeyHex)
    }

    // MARK: - Binary Format (32 bytes exact)

    func testBinaryFormat32BytesReturnsRawKey() throws {
        let data = try fixtureData("test-binary", ext: "key")
        let result = try KeyFileProcessor.processKeyFile(data)
        XCTAssertEqual(result, expectedKey)
        XCTAssertEqual(result.count, 32)
    }

    func testBinaryFormatDetection() {
        let data = Data(repeating: 0xAB, count: 32)
        let result = KeyFileProcessor.tryBinaryFormat(data)
        XCTAssertEqual(result, data)
    }

    func testBinaryFormatRejectsNon32Bytes() {
        XCTAssertNil(KeyFileProcessor.tryBinaryFormat(Data(repeating: 0, count: 31)))
        XCTAssertNil(KeyFileProcessor.tryBinaryFormat(Data(repeating: 0, count: 33)))
    }

    // MARK: - Hex Format (64 hex chars)

    func testHexFormat64CharsDecodesTo32Bytes() throws {
        let data = try fixtureData("test-hex", ext: "key")
        let result = try KeyFileProcessor.processKeyFile(data)
        XCTAssertEqual(result, expectedKey)
        XCTAssertEqual(result.count, 32)
    }

    func testHexFormatDetection() {
        let hex = "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"
        let data = Data(hex.utf8)
        let result = KeyFileProcessor.tryHexFormat(data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 32)
    }

    func testHexFormatRejectsInvalidChars() {
        let bad = String(repeating: "ZZ", count: 32) // 64 chars but not hex
        let data = Data(bad.utf8)
        let result = KeyFileProcessor.tryHexFormat(data)
        XCTAssertNil(result)
    }

    // MARK: - XML v1.0 Format (base64)

    func testXMLv1FormatParsesBase64Key() throws {
        let data = try fixtureData("test-v1", ext: "key")
        let result = try KeyFileProcessor.processKeyFile(data)
        XCTAssertEqual(result, expectedKey)
        XCTAssertEqual(result.count, 32)
    }

    // MARK: - XML v2.0 Format (hex + hash verify)

    func testXMLv2FormatParsesHexKeyWithHashVerification() throws {
        let data = try fixtureData("test-v2", ext: "keyx")
        let result = try KeyFileProcessor.processKeyFile(data)
        XCTAssertEqual(result, expectedKey)
        XCTAssertEqual(result.count, 32)
    }

    func testXMLv2WithBadHashThrows() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <KeyFile>
          <Meta><Version>2.0</Version></Meta>
          <Key>
            <Data Hash="DEADBEEF">
              000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F
            </Data>
          </Key>
        </KeyFile>
        """
        XCTAssertThrowsError(try KeyFileProcessor.processKeyFile(Data(xml.utf8))) { error in
            XCTAssertEqual(error as? KeyFileProcessor.KeyFileError, .xmlHashMismatch)
        }
    }

    // MARK: - Fallback (SHA-256)

    func testFallbackHasheArbitraryFile() throws {
        let data = try fixtureData("test-arbitrary", ext: "key")
        let result = try KeyFileProcessor.processKeyFile(data)
        let expected = Data(SHA256.hash(data: data))
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.count, 32)
    }

    // MARK: - Edge Cases

    func testEmptyFileThrows() {
        XCTAssertThrowsError(try KeyFileProcessor.processKeyFile(Data())) { error in
            XCTAssertEqual(error as? KeyFileProcessor.KeyFileError, .emptyKeyFile)
        }
    }

    func testHashFallbackIsDeterministic() {
        let data = Data("test input".utf8)
        let result1 = KeyFileProcessor.hashFallback(data)
        let result2 = KeyFileProcessor.hashFallback(data)
        XCTAssertEqual(result1, result2)
    }

    // MARK: - Composite Key Tests

    func testCompositeKeyPasswordOnly() throws {
        // Password-only should match legacy behavior: SHA256(SHA256(password))
        let password = "testpassword"
        let legacy = KDBXCrypto.compositeKey(password: password)
        let composite = try KDBXCrypto.compositeKey(password: password, keyFileData: nil)
        XCTAssertEqual(legacy, composite)

        let legacyEmpty = KDBXCrypto.compositeKey(password: "")
        let compositeEmpty = try KDBXCrypto.compositeKey(password: "", keyFileData: nil)
        XCTAssertEqual(legacyEmpty, compositeEmpty)
    }

    func testCompositeKeyWithKeyFile() throws {
        let password = "demo"
        let keyFileData = try fixtureData("test-binary", ext: "key")

        let composite = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)

        // Manual computation: SHA256(SHA256("demo") || processKeyFile(binaryKey))
        let pwdHash = Data(SHA256.hash(data: Data(password.utf8)))
        let keyFileKey = try KeyFileProcessor.processKeyFile(keyFileData)
        var preKey = Data()
        preKey.append(pwdHash)
        preKey.append(keyFileKey)
        let expected = Data(SHA256.hash(data: preKey))

        XCTAssertEqual(composite, expected)
    }

    func testCompositeKeyKeyFileOnly() throws {
        let keyFileData = try fixtureData("test-binary", ext: "key")

        let composite = try KDBXCrypto.compositeKey(password: nil, keyFileData: keyFileData)

        // Key file only: SHA256(processKeyFile(keyFileData))
        let keyFileKey = try KeyFileProcessor.processKeyFile(keyFileData)
        let expected = Data(SHA256.hash(data: keyFileKey))

        XCTAssertEqual(composite, expected)
    }

    func testCompositeKeyEmptyPasswordWithKeyFileEqualsKeyFileOnly() throws {
        let keyFileData = try fixtureData("test-binary", ext: "key")

        let withEmpty = try KDBXCrypto.compositeKey(password: "", keyFileData: keyFileData)
        let withNil = try KDBXCrypto.compositeKey(password: nil, keyFileData: keyFileData)

        XCTAssertEqual(withEmpty, withNil, "Empty password should be treated same as no password")
    }

    func testCompositeKeyRejectsMalformedXMLKeyFileInsteadOfDroppingIt() {
        let malformedKeyFile = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <KeyFile>
          <Meta><Version>1.0</Version></Meta>
          <Key><Data>not-a-32-byte-key</Data></Key>
        </KeyFile>
        """.utf8)

        for password in [nil, "password"] as [String?] {
            XCTAssertThrowsError(
                try KDBXCrypto.compositeKey(password: password, keyFileData: malformedKeyFile)
            ) { error in
                XCTAssertEqual(error as? KeyFileProcessor.KeyFileError, .xmlKeyDataInvalid)
            }
        }
    }

    func testCompositeKeyRejectsXMLKeyFileWithMismatchedHash() {
        let malformedKeyFile = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <KeyFile>
          <Meta><Version>2.0</Version></Meta>
          <Key>
            <Data Hash="DEADBEEF">
              000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F
            </Data>
          </Key>
        </KeyFile>
        """.utf8)

        XCTAssertThrowsError(
            try KDBXCrypto.compositeKey(password: nil, keyFileData: malformedKeyFile)
        ) { error in
            XCTAssertEqual(error as? KeyFileProcessor.KeyFileError, .xmlHashMismatch)
        }
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String, ext: String) throws -> Data {
        let bundle = Bundle(for: KeyFileProcessorTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    private func dataFromHex(_ hex: String) -> Data {
        let chars = Array(hex)
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            let byte = UInt8(String(chars[i...i + 1]), radix: 16)!
            data.append(byte)
        }
        return data
    }
}
