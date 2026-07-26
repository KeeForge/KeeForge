import CryptoKit
import XCTest
@testable import KeeForge

final class EncryptedValueTests: XCTestCase {
    private let testKey = SymmetricKey(size: .bits256)

    func testRoundTripEncryptDecrypt() throws {
        let original = "hunter2"
        let encrypted = try EncryptedValue.encrypt(original, using: testKey)
        let decrypted = try encrypted.decrypt(using: testKey)
        XCTAssertEqual(decrypted, original)
    }

    func testEmptyStringProducesEmpty() throws {
        let encrypted = try EncryptedValue.encrypt("", using: testKey)
        XCTAssertEqual(encrypted.hasValue, false)
        XCTAssertEqual(encrypted.sealedData, Data())
    }

    func testEmptyDecryptsToEmptyString() throws {
        let decrypted = try EncryptedValue.empty.decrypt(using: testKey)
        XCTAssertEqual(decrypted, "")
    }

    func testHasValueTrueForNonEmpty() throws {
        let encrypted = try EncryptedValue.encrypt("secret", using: testKey)
        XCTAssertTrue(encrypted.hasValue)
    }

    func testHasValueFalseForEmpty() {
        XCTAssertFalse(EncryptedValue.empty.hasValue)
    }

    func testDecryptWithWrongKeyThrows() throws {
        let encrypted = try EncryptedValue.encrypt("secret", using: testKey)
        let wrongKey = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try encrypted.decrypt(using: wrongKey))
    }

    func testUnicodeRoundTrip() throws {
        let original = "pässwörd!@#¥ 🔑 日本語"
        let encrypted = try EncryptedValue.encrypt(original, using: testKey)
        let decrypted = try encrypted.decrypt(using: testKey)
        XCTAssertEqual(decrypted, original)
    }

    // MARK: - Data overloads

    // The Data-based overloads carry pre-decoded TOTP secrets and other raw
    // key material that never round-trips through String, so they are pinned
    // separately from the String overloads above.

    func testDataRoundTripEncryptDecrypt() throws {
        let original = Data([0x00, 0x01, 0x02, 0x7F, 0x80, 0xFE, 0xFF])
        let encrypted = try EncryptedValue.encrypt(original, using: testKey)

        XCTAssertTrue(encrypted.hasValue)
        XCTAssertEqual(try encrypted.decryptData(using: testKey), original)
    }

    func testEmptyDataProducesEmptySentinel() throws {
        let encrypted = try EncryptedValue.encrypt(Data(), using: testKey)

        XCTAssertEqual(encrypted, .empty)
        XCTAssertFalse(encrypted.hasValue)
        XCTAssertEqual(encrypted.sealedData, Data())
    }

    func testEmptyDecryptsToEmptyData() throws {
        XCTAssertEqual(try EncryptedValue.empty.decryptData(using: testKey), Data())
    }

    func testDecryptDataWithWrongKeyThrows() throws {
        let encrypted = try EncryptedValue.encrypt(Data([0xDE, 0xAD, 0xBE, 0xEF]), using: testKey)
        let wrongKey = SymmetricKey(size: .bits256)

        XCTAssertThrowsError(try encrypted.decryptData(using: wrongKey))
    }

    func testTamperedSealedDataFailsAuthentication() throws {
        let encrypted = try EncryptedValue.encrypt(Data([0xDE, 0xAD, 0xBE, 0xEF]), using: testKey)
        var tampered = encrypted.sealedData
        tampered[tampered.count - 1] ^= 0x01

        XCTAssertThrowsError(
            try EncryptedValue(sealedData: tampered, hasValue: true).decryptData(using: testKey)
        )
    }

    func testNonUTF8DataDecryptsAsEmptyStringButSurvivesAsBytes() throws {
        // Raw secret bytes are not text: reading them back through the String
        // overload must fail closed rather than emit replacement characters.
        let original = Data([0xFF, 0xFE, 0xFD])
        let encrypted = try EncryptedValue.encrypt(original, using: testKey)

        XCTAssertEqual(try encrypted.decrypt(using: testKey), "")
        XCTAssertEqual(try encrypted.decryptData(using: testKey), original)
    }

    func testStringAndDataOverloadsAgreeOnUTF8Payloads() throws {
        let original = "pässwörd 🔑"
        let viaString = try EncryptedValue.encrypt(original, using: testKey)
        let viaData = try EncryptedValue.encrypt(Data(original.utf8), using: testKey)

        XCTAssertEqual(try viaString.decryptData(using: testKey), Data(original.utf8))
        XCTAssertEqual(try viaData.decrypt(using: testKey), original)
    }

    func testEachEncryptProducesDifferentCiphertext() throws {
        let a = try EncryptedValue.encrypt("same", using: testKey)
        let b = try EncryptedValue.encrypt("same", using: testKey)
        // Different random nonces mean different sealed data
        XCTAssertNotEqual(a.sealedData, b.sealedData)
        // But both decrypt to the same value
        XCTAssertEqual(try a.decrypt(using: testKey), try b.decrypt(using: testKey))
    }
}
