import CryptoKit
import XCTest
@testable import KeeForge

/// KeePassXC-compatible YubiKey challenge-response key derivation, pinned
/// against `challenge-response.kdbx` — a pykeepass-authored database whose key
/// the generator derived independently (`TestFixtures/generators/challenge_response.py`).
final class ChallengeResponseKeyTests: XCTestCase {
    func testChallengeIsTheArgon2SaltPaddedToSixtyFourBytes() throws {
        let data = try KDBXTestFixture.challengeResponse.data(in: bundle)

        let challenge = try ChallengeResponseKey.challenge(forDatabase: data)

        var reader = DataReader(data: data)
        _ = try KDBXParser.parseVersion(from: &reader)
        let salt = try XCTUnwrap(KDBXParser.parseHeader(&reader).kdfParameters["S"] as? Data)
        XCTAssertEqual(salt.count, 32)
        XCTAssertEqual(challenge.count, 64)
        XCTAssertEqual(challenge.prefix(32), salt)
        XCTAssertEqual(Array(challenge.suffix(32)), Array(repeating: 0x20, count: 32))
    }

    func testChallengeIsRefusedForKDBX31() throws {
        let data = try KDBXTestFixture.legacyKDBX31.data(in: bundle)

        XCTAssertThrowsError(try ChallengeResponseKey.challenge(forDatabase: data)) { error in
            XCTAssertEqual(error as? HardwareKeyError, .unsupportedDatabase)
        }
    }

    // KeePassXC writes KDBX 4 AES-KDF under the legacy UUID and folds the
    // response in before it, with the AES-KDF seed as the challenge.
    func testFixtureWithAESKDFOpensWithPasswordAndYubiKeyResponse() throws {
        let fixture = KDBXTestFixture.challengeResponseAESKDF
        let data = try fixture.data(in: bundle)
        var reader = DataReader(data: data)
        _ = try KDBXParser.parseVersion(from: &reader)
        let kdfParameters = try KDBXParser.parseHeader(&reader).kdfParameters
        XCTAssertEqual(kdfParameters["$UUID"] as? Data, KDBXParser.aesKDFUUID)
        let seed = try XCTUnwrap(kdfParameters["S"] as? Data)

        let challenge = try ChallengeResponseKey.challenge(forDatabase: data)
        XCTAssertEqual(challenge.prefix(32), seed)
        XCTAssertEqual(Array(challenge.suffix(32)), Array(repeating: 0x20, count: 32))

        let compositeKey = ChallengeResponseKey.compositeKey(
            preKey: try KDBXCrypto.preKey(password: fixture.password, keyFileData: nil),
            response: YubiKeyEmulator.response(to: challenge)
        )
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            compositeKey: compositeKey,
            sessionKey: SymmetricKey(size: .bits256)
        )

        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first { $0.title == "YubiKey Entry" })
        XCTAssertEqual(entry.username, "yubikey-user")
        XCTAssertThrowsError(try fixture.parse(in: bundle, sessionKey: SymmetricKey(size: .bits256)))
    }

    func testCompositeKeyMatchesKeePassXCForPassword() throws {
        let preKey = try KDBXCrypto.preKey(password: "password", keyFileData: nil)

        let composite = ChallengeResponseKey.compositeKey(preKey: preKey, response: Data(0..<20))

        XCTAssertEqual(
            composite.withUnsafeBytes { Data($0) }.hexString,
            "209ff8ff8aa936ff48897c2bdc1292f3fc99cb6a17ee92ddc0120ee0fd7baa2f"
        )
    }

    func testCompositeKeyMatchesKeePassXCForPasswordAndKeyFile() throws {
        let preKey = try KDBXCrypto.preKey(password: "password", keyFileData: Data(0..<32))

        let composite = ChallengeResponseKey.compositeKey(preKey: preKey, response: Data(0..<20))

        XCTAssertEqual(
            composite.withUnsafeBytes { Data($0) }.hexString,
            "4e38c0315dc6710ee26c71e363dd87c65a194c5253bc611b85542b940d451d3d"
        )
    }

    func testCompositeKeyMatchesKeePassXCForYubiKeyAlone() throws {
        let preKey = try KDBXCrypto.preKey(password: nil, keyFileData: nil)

        let composite = ChallengeResponseKey.compositeKey(preKey: preKey, response: Data(0..<20))

        XCTAssertEqual(
            composite.withUnsafeBytes { Data($0) }.hexString,
            "dc732db5a276cc62ed10ce2763bb1fea542b2c4fa3cd2f5e46936d217c9d1c04"
        )
    }

    func testCompositeKeyWithoutResponseIsUnchangedByPreKeySplit() throws {
        let keyFile = Data(0..<32)

        let preKey = try KDBXCrypto.preKey(password: "password", keyFileData: keyFile)
        let composite = try KDBXCrypto.compositeKey(password: "password", keyFileData: keyFile)

        XCTAssertEqual(preKey.bitCount, 512)
        XCTAssertEqual(
            composite.withUnsafeBytes { Data($0) },
            preKey.withUnsafeBytes { Data(SHA256.hash(data: $0)) }
        )
    }

    func testFixtureOpensWithPasswordAndYubiKeyResponse() throws {
        let fixture = KDBXTestFixture.challengeResponse
        let data = try fixture.data(in: bundle)
        let challenge = try ChallengeResponseKey.challenge(forDatabase: data)
        let preKey = try KDBXCrypto.preKey(password: fixture.password, keyFileData: nil)
        let compositeKey = ChallengeResponseKey.compositeKey(
            preKey: preKey,
            response: YubiKeyEmulator.response(to: challenge)
        )

        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            compositeKey: compositeKey,
            sessionKey: SymmetricKey(size: .bits256)
        )

        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first { $0.title == "YubiKey Entry" })
        XCTAssertEqual(entry.username, "yubikey-user")
    }

    func testFixtureRejectsPasswordAlone() throws {
        XCTAssertThrowsError(try KDBXTestFixture.challengeResponse.parse(
            in: bundle,
            sessionKey: SymmetricKey(size: .bits256)
        ))
    }

    func testFixtureRejectsAnotherYubiKey() throws {
        let fixture = KDBXTestFixture.challengeResponse
        let data = try fixture.data(in: bundle)
        let challenge = try ChallengeResponseKey.challenge(forDatabase: data)
        let compositeKey = ChallengeResponseKey.compositeKey(
            preKey: try KDBXCrypto.preKey(password: fixture.password, keyFileData: nil),
            response: YubiKeyEmulator.response(to: challenge, secret: Data("another-yubikey-secr".utf8))
        )

        XCTAssertThrowsError(try KDBXParser.parseWithMetaAndHeader(
            data: data,
            compositeKey: compositeKey,
            sessionKey: SymmetricKey(size: .bits256)
        ))
    }

    private var bundle: Bundle {
        Bundle(for: Self.self)
    }
}
