import XCTest
@testable import KDBXKit

final class KDBXOuterCipherTests: XCTestCase {
    func testUUIDsMatchKeePass() {
        XCTAssertEqual(KDBXOuterCipher.aes256CBC.uuid.hex, "31c1f2e6bf714350be5805216afc5aff")
        XCTAssertEqual(KDBXOuterCipher.chaCha20.uuid.hex, "d6038a2b8b6f4cb5a524339a31dbb59a")
        XCTAssertEqual(KDBXOuterCipher.twofish256CBC.uuid.hex, "ad68f29f576f4bb9a36ad47af965346c")
        for cipher in KDBXOuterCipher.allCases {
            XCTAssertEqual(KDBXOuterCipher(uuid: cipher.uuid), cipher)
            XCTAssertEqual(try KDBXOuterCipher.require(uuid: cipher.uuid), cipher)
        }
    }

    func testUnknownUUIDIsNilOrUnsupported() {
        let serpent = Data(hex: "098563ffdde3443fa04fbbc87af2bd8e")
        XCTAssertNil(KDBXOuterCipher(uuid: serpent))
        assertThrows(KDBXCrypto.CryptoError.unsupportedCipher(serpent)) { try KDBXOuterCipher.require(uuid: serpent) }
    }

    func testDescriptiveProperties() {
        XCTAssertEqual(KDBXOuterCipher.allCases.map(\.displayName), ["AES-256", "ChaCha20", "Twofish-256-CBC"])
        XCTAssertEqual(KDBXOuterCipher.allCases.map(\.encryptionIVLength), [16, 12, 16])
        XCTAssertEqual(KDBXOuterCipher.allCases.map(\.supportsKDBX3), [true, false, true])
    }

    func testEveryCipherRoundTripsThroughItsPrimitive() throws {
        let key = Data(repeating: 7, count: 32)
        let plaintext = Data((0..<100).map { UInt8($0) })
        for cipher in KDBXOuterCipher.allCases {
            let iv = Data(repeating: 9, count: cipher.encryptionIVLength)
            let ciphertext = try cipher.encrypt(data: plaintext, key: key, iv: iv)
            XCTAssertNotEqual(ciphertext.prefix(100), plaintext)
            XCTAssertEqual(try cipher.decrypt(data: ciphertext, key: key, iv: iv), plaintext, "\(cipher)")
        }
        XCTAssertEqual(
            try KDBXOuterCipher.chaCha20.encrypt(data: plaintext, key: key, iv: Data(repeating: 9, count: 12)),
            try KDBXCrypto.chaCha20(data: plaintext, key: key, nonce: Data(repeating: 9, count: 12))
        )
        XCTAssertEqual(
            try KDBXOuterCipher.twofish256CBC.encrypt(data: plaintext, key: key, iv: Data(repeating: 9, count: 16)),
            try KDBXCrypto.encryptTwofish256CBC(data: plaintext, key: key, iv: Data(repeating: 9, count: 16))
        )
        XCTAssertEqual(
            try KDBXOuterCipher.aes256CBC.encrypt(data: plaintext, key: key, iv: Data(repeating: 9, count: 16)),
            try KDBXCrypto.encryptAES256CBC(data: plaintext, key: key, iv: Data(repeating: 9, count: 16))
        )
    }
}
