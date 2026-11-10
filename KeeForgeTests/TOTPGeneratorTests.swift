import CryptoKit
import XCTest
@testable import KeeForge

/// The app adapter over `OneTimeCodes`: decryption under the session key, the
/// `decodedSecret` precedence, and the placeholder. The algorithm's known
/// answers are in the package's own tests.
final class TOTPGeneratorTests: XCTestCase {
    private let testKey = SymmetricKey(size: .bits256)
    /// RFC 6238 Appendix B's SHA-1 seed, "12345678901234567890", in Base32.
    private static let rfc6238Seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    private static let t59 = Date(timeIntervalSince1970: 59)

    private func seal(_ secret: String) -> EncryptedValue {
        try! EncryptedValue.encrypt(secret, using: testKey)
    }

    func testGeneratesFromTheDecryptedBase32Secret() {
        let config = TOTPConfig(secret: seal(Self.rfc6238Seed), digits: 8)

        XCTAssertEqual(TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Self.t59), "94287082")
        XCTAssertEqual(
            TOTPGenerator.decryptedSecret(config: config, sessionKey: testKey),
            Data("12345678901234567890".utf8)
        )
    }

    func testCarriesTheConfigTimingIntoTheParameters() throws {
        let config = TOTPConfig(secret: seal(Self.rfc6238Seed), period: 0, digits: 20, algorithm: .sha256)

        let parameters = try XCTUnwrap(TOTPGenerator.parameters(for: config, sessionKey: testKey))

        XCTAssertEqual(parameters.period, 1, "clamped by the package")
        XCTAssertEqual(parameters.digits, 9, "clamped by the package")
        XCTAssertEqual(parameters.algorithm, .sha256)
    }

    func testPredecodedSecretTakesPrecedenceOverTheBase32Field() throws {
        // Python hmac/hashlib SHA-1 reference and the RFC 6238 SHA-1 seed at counter 1.
        let vectors: [(secret: Data, code: String)] = [
            (Data([0x00, 0x01, 0x02, 0xFE, 0xFF]), "388061"),
            (Data("12345678901234567890".utf8), "287082"),
        ]
        for vector in vectors {
            let config = TOTPConfig(
                secret: seal("preserved-source"),
                decodedSecret: try EncryptedValue.encrypt(vector.secret, using: testKey)
            )

            XCTAssertEqual(TOTPGenerator.decryptedSecret(config: config, sessionKey: testKey), vector.secret)
            XCTAssertEqual(TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Self.t59), vector.code)
        }
    }

    func testEmptyPredecodedSecretDoesNotFallBackToTheBase32Field() {
        let config = TOTPConfig(secret: seal(Self.rfc6238Seed), decodedSecret: .empty)

        XCTAssertNil(TOTPGenerator.parameters(for: config, sessionKey: testKey))
        XCTAssertEqual(TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Self.t59), "------")
    }

    func testUnresolvableSecretsShowThePlaceholder() throws {
        let foreignKey = SymmetricKey(size: .bits256)
        let configs = [
            TOTPConfig(secret: seal("not_base32***")),
            TOTPConfig(secret: seal("")),
            TOTPConfig(secret: seal("===")),
            TOTPConfig(secret: try EncryptedValue.encrypt(Self.rfc6238Seed, using: foreignKey)),
            TOTPConfig(secret: seal(Self.rfc6238Seed), decodedSecret: try EncryptedValue.encrypt(Data([1]), using: foreignKey)),
        ]

        for config in configs {
            XCTAssertNil(TOTPGenerator.parameters(for: config, sessionKey: testKey))
            XCTAssertEqual(TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Self.t59), "------")
        }
        XCTAssertEqual(TOTPGenerator.code(for: nil, at: Self.t59), TOTPGenerator.placeholderCode)
        XCTAssertEqual(TOTPGenerator.placeholderCode, "------")
    }

    func testBase32DecodeForwarderMatchesThePackage() {
        // `KDBXParser` decodes stored secrets through this name.
        XCTAssertEqual(TOTPGenerator.base32Decode("jbsw y3dp="), Data("Hello".utf8))
        XCTAssertNil(TOTPGenerator.base32Decode("1NVALID"))
    }
}
