import CryptoKit
import XCTest
@testable import KDBXKit

final class KDBXCryptoTests: XCTestCase {
    private let keyFileKey = Data((0..<32).map { UInt8($0) })

    // MARK: - Composite key

    func testPasswordCompositeKeyIsDoubleSHA256() {
        let expected = Data(SHA256.hash(data: Data(SHA256.hash(data: Data("pässword".utf8)))))
        XCTAssertEqual(KDBXCrypto.compositeKey(password: "pässword").bytes, expected)
    }

    func testEmptyPasswordContributesNothing() throws {
        let emptyHash = Data(SHA256.hash(data: Data()))
        XCTAssertEqual(KDBXCrypto.compositeKey(password: "").bytes, emptyHash)
        XCTAssertEqual(try KDBXCrypto.compositeKey(password: "", keyFileData: nil).bytes, emptyHash)
        XCTAssertEqual(try KDBXCrypto.compositeKey(password: nil, keyFileData: nil).bytes, emptyHash)
        XCTAssertEqual(try KDBXCrypto.preKey(password: "", keyFileData: nil).bitCount, 0)
    }

    func testPasswordOnlyFormsAgree() throws {
        XCTAssertEqual(KDBXCrypto.compositeKey(password: "pw"), try KDBXCrypto.compositeKey(password: "pw", keyFileData: nil))
    }

    func testPreKeyConcatenatesPasswordHashAndKeyFileKey() throws {
        let passwordHash = Data(SHA256.hash(data: Data("demo".utf8)))
        XCTAssertEqual(try KDBXCrypto.preKey(password: "demo", keyFileData: keyFileKey).bytes, passwordHash + keyFileKey)
        XCTAssertEqual(try KDBXCrypto.preKey(password: nil, keyFileData: keyFileKey).bytes, keyFileKey)
        XCTAssertEqual(try KDBXCrypto.preKey(password: "", keyFileData: keyFileKey).bytes, keyFileKey)
        XCTAssertEqual(try KDBXCrypto.preKey(password: "demo", keyFileData: nil).bytes, passwordHash)
    }

    func testCompositeKeyHashesThePreKey() throws {
        let preKey = try KDBXCrypto.preKey(password: "demo", keyFileData: keyFileKey).bytes
        XCTAssertEqual(
            try KDBXCrypto.compositeKey(password: "demo", keyFileData: keyFileKey).bytes,
            Data(SHA256.hash(data: preKey))
        )
    }

    func testKeyFileErrorsPropagate() {
        assertThrows(KDBXKeyFile.KeyFileError.emptyKeyFile) {
            try KDBXCrypto.compositeKey(password: "pw", keyFileData: Data())
        }
    }

    // MARK: - Hashes

    func testHashesMatchCryptoKit() {
        let input = Data("abc".utf8)
        XCTAssertEqual(KDBXCrypto.sha256(input).hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(KDBXCrypto.sha512(input).prefix(8).hex, "ddaf35a193617aba")
        // RFC 4231 test case 2.
        XCTAssertEqual(
            KDBXCrypto.hmacSHA256(key: Data("Jefe".utf8), data: Data("what do ya want for nothing?".utf8)).hex,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
    }

    // MARK: - AES-256-CBC

    /// NIST SP 800-38A F.2.5, plus the PKCS#7 block CommonCrypto appends.
    func testAESCBCMatchesNISTVector() throws {
        let key = Data(hex: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let plaintext = Data(hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let ciphertext = try KDBXCrypto.encryptAES256CBC(data: plaintext, key: key, iv: iv)
        XCTAssertEqual(ciphertext.count, 48)
        XCTAssertEqual(ciphertext.prefix(32).hex, "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d")
        XCTAssertEqual(try KDBXCrypto.decryptAES256CBC(data: ciphertext, key: key, iv: iv), plaintext)
    }

    func testAESCBCRejectsBadKeyIVAndCiphertext() throws {
        let key = Data(count: 32), iv = Data(count: 16)
        assertThrows(KDBXCrypto.CryptoError.encryptionFailed) { try KDBXCrypto.encryptAES256CBC(data: Data(), key: Data(count: 16), iv: iv) }
        assertThrows(KDBXCrypto.CryptoError.encryptionFailed) { try KDBXCrypto.encryptAES256CBC(data: Data(), key: key, iv: Data(count: 12)) }
        assertThrows(KDBXCrypto.CryptoError.decryptionFailed) { try KDBXCrypto.decryptAES256CBC(data: Data(count: 16), key: Data(count: 31), iv: iv) }
        assertThrows(KDBXCrypto.CryptoError.decryptionFailed) { try KDBXCrypto.decryptAES256CBC(data: Data(count: 15), key: key, iv: iv) }

        var ciphertext = try KDBXCrypto.encryptAES256CBC(data: Data("x".utf8), key: key, iv: iv)
        ciphertext[0] ^= 0xFF
        assertThrows(KDBXCrypto.CryptoError.decryptionFailed) { try KDBXCrypto.decryptAES256CBC(data: ciphertext, key: key, iv: iv) }
    }

    // MARK: - Twofish-256-CBC

    /// Twofish paper's ECB_TBL.TXT, 256-bit key, I=1: with a zero IV the
    /// first CBC block is the ECB block.
    func testTwofishCBCMatchesTheReferenceVector() throws {
        let ciphertext = try KDBXCrypto.encryptTwofish256CBC(data: Data(count: 16), key: Data(count: 32), iv: Data(count: 16))
        XCTAssertEqual(ciphertext.count, 32)
        XCTAssertEqual(ciphertext.prefix(16).hex, "57ff739d4dc92c1bd7fc01700cc8216f")
        XCTAssertEqual(try KDBXCrypto.decryptTwofish256CBC(data: ciphertext, key: Data(count: 32), iv: Data(count: 16)), Data(count: 16))
    }

    func testTwofishCBCNormalizesErrors() {
        assertThrows(KDBXCrypto.CryptoError.encryptionFailed) {
            try KDBXCrypto.encryptTwofish256CBC(data: Data(), key: Data(count: 16), iv: Data(count: 16))
        }
        assertThrows(KDBXCrypto.CryptoError.decryptionFailed) {
            try KDBXCrypto.decryptTwofish256CBC(data: Data(count: 15), key: Data(count: 32), iv: Data(count: 16))
        }
    }

    // MARK: - ChaCha20

    private static let rfc8439A1Blocks0And1 = Data(hex: """
        76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7
        da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586
        9f07e7be5551387a98ba977c732d080dcb0f29a048e3656912c6533e32ee7aed
        29b721769ce64e43d57133b074d839d531ed1f28510afb45ace10a1f4b794d6f
        """)

    /// RFC 8439 Appendix A.1, test vectors #1 and #2: zero key and nonce,
    /// block counters 0 and 1.
    func testChaCha20MatchesRFC8439AppendixA1() throws {
        let output = try KDBXCrypto.chaCha20(data: Data(count: 128), key: Data(count: 32), nonce: Data(count: 12))
        XCTAssertEqual(output, Self.rfc8439A1Blocks0And1)
        XCTAssertEqual(try KDBXCrypto.chaCha20(data: output, key: Data(count: 32), nonce: Data(count: 12)), Data(count: 128))
    }

    /// RFC 8439 §2.4.2. The vector starts at block counter 1, so one block of
    /// keystream is skipped first.
    func testChaCha20MatchesRFC8439SunscreenVector() throws {
        let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let output = try KDBXCrypto.chaCha20(
            data: Data(count: 64) + plaintext,
            key: Data((0..<32).map { UInt8($0) }),
            nonce: Data(hex: "000000000000004a00000000")
        )
        XCTAssertEqual(output.dropFirst(64).hex, """
            6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b\
            f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8\
            07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736\
            5af90bbf74a35be6b40b8eedf2785e42874d
            """)
    }

    func testChaCha20RejectsWrongKeyOrNonceSize() {
        assertThrows(KDBXCrypto.CryptoError.invalidKey) {
            try KDBXCrypto.chaCha20(data: Data(count: 1), key: Data(count: 31), nonce: Data(count: 12))
        }
        assertThrows(KDBXCrypto.CryptoError.invalidKey) {
            try KDBXCrypto.chaCha20(data: Data(count: 1), key: Data(count: 32), nonce: Data(count: 8))
        }
    }

    func testChaCha20AcceptsSlices() throws {
        let key = Data(count: 32).asSlice, nonce = Data(count: 12).asSlice
        XCTAssertEqual(try KDBXCrypto.chaCha20(data: Data(count: 128).asSlice, key: key, nonce: nonce), Self.rfc8439A1Blocks0And1)
    }

    func testKeystreamIsContinuousAcrossCalls() {
        let key = Data((0..<32).map { UInt8($0) })
        let nonce = Data((0..<12).map { UInt8(0xA0 + $0) })
        let plaintext = Data((0..<300).map { UInt8($0 % 251) })

        var chunked = KDBXCrypto.ChaCha20Keystream(key: key, nonce: nonce)
        var incremental = Data()
        var start = 0
        for length in [63, 1, 0, 64, 65, 107] {
            incremental += chunked.xor(plaintext.subdata(in: start..<(start + length)))
            start += length
        }
        XCTAssertEqual(start, plaintext.count)

        var single = KDBXCrypto.ChaCha20Keystream(key: key, nonce: nonce)
        XCTAssertEqual(incremental, single.xor(plaintext))
    }

    func testWipeDiscardsTheKey() {
        let key = Data(repeating: 0x5A, count: 32), nonce = Data(repeating: 0x17, count: 12)
        var reference = KDBXCrypto.ChaCha20Keystream(key: key, nonce: nonce)
        var wiped = KDBXCrypto.ChaCha20Keystream(key: key, nonce: nonce)
        _ = wiped.xor(Data(count: 10))
        wiped.wipe()
        _ = reference.xor(Data(count: 10))
        XCTAssertNotEqual(wiped.xor(Data(count: 64)), reference.xor(Data(count: 64)))
    }
}
