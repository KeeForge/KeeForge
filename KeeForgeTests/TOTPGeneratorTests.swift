import CryptoKit
import XCTest
@testable import KeeForge

final class TOTPGeneratorTests: XCTestCase {
    private let testKey = SymmetricKey(size: .bits256)

    private func encryptSecret(_ secret: String) -> EncryptedValue {
        try! EncryptedValue.encrypt(secret, using: testKey)
    }

    func testGenerateCodeSHA1RFC6238Vector() {
        let config = TOTPConfig(
            secret: encryptSecret("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"),
            period: 30,
            digits: 8,
            algorithm: .sha1
        )

        let code = TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Date(timeIntervalSince1970: 59))

        XCTAssertEqual(code, "94287082")
    }

    /// RFC 6238 Appendix B uses a different seed length per algorithm: 20 bytes
    /// for SHA-1, 32 for SHA-256 and 64 for SHA-512, each the ASCII string
    /// "12345678901234567890" repeated and truncated. These are their Base32
    /// encodings.
    private static let rfc6238Seed256 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA===="
    private static let rfc6238Seed512 =
        "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" +
        "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA="

    func testGenerateCodeSHA256RFC6238Vectors() {
        let config = TOTPConfig(
            secret: encryptSecret(Self.rfc6238Seed256),
            period: 30,
            digits: 8,
            algorithm: .sha256
        )

        for (time, expected) in [(59, "46119246"), (1_111_111_109, "68084774"), (1_234_567_890, "91819424")] {
            XCTAssertEqual(
                TOTPGenerator.generateCode(
                    config: config,
                    sessionKey: testKey,
                    date: Date(timeIntervalSince1970: TimeInterval(time))
                ),
                expected,
                "RFC 6238 SHA-256 vector at T=\(time)"
            )
        }
    }

    func testGenerateCodeSHA512RFC6238Vectors() {
        let config = TOTPConfig(
            secret: encryptSecret(Self.rfc6238Seed512),
            period: 30,
            digits: 8,
            algorithm: .sha512
        )

        for (time, expected) in [(59, "90693936"), (1_111_111_109, "25091201"), (1_234_567_890, "93441116")] {
            XCTAssertEqual(
                TOTPGenerator.generateCode(
                    config: config,
                    sessionKey: testKey,
                    date: Date(timeIntervalSince1970: TimeInterval(time))
                ),
                expected,
                "RFC 6238 SHA-512 vector at T=\(time)"
            )
        }
    }

    func testGenerateCodeAlgorithmSelectionChangesTheCode() {
        // Guards against an algorithm switch that silently falls back to
        // SHA-1: the same seed and timestamp must produce distinct codes.
        func code(_ secret: String, _ algorithm: TOTPAlgorithm) -> String {
            TOTPGenerator.generateCode(
                config: TOTPConfig(secret: encryptSecret(secret), period: 30, digits: 8, algorithm: algorithm),
                sessionKey: testKey,
                date: Date(timeIntervalSince1970: 59)
            )
        }

        XCTAssertEqual(Set([
            code("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", .sha1),
            code(Self.rfc6238Seed256, .sha256),
            code(Self.rfc6238Seed512, .sha512),
        ]).count, 3)
    }

    func testGenerateCodeUsesPredecodedBinarySecret() throws {
        let secret = Data([0x00, 0x01, 0x02, 0xFE, 0xFF])
        let config = TOTPConfig(
            secret: encryptSecret("preserved-source"),
            decodedSecret: try EncryptedValue.encrypt(secret, using: testKey),
            period: 30,
            digits: 6,
            algorithm: .sha1
        )

        let resolved = try XCTUnwrap(TOTPGenerator.resolveSecret(config: config, sessionKey: testKey))
        XCTAssertEqual(resolved.data, secret)
        XCTAssertNotEqual(
            TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Date(timeIntervalSince1970: 59)),
            "------"
        )
    }

    func testGenerateCodeReturnsPlaceholderForEmptyPredecodedSecret() {
        let config = TOTPConfig(
            secret: encryptSecret("ignored"), decodedSecret: .empty, period: 30, digits: 6, algorithm: .sha1
        )

        XCTAssertEqual(
            TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Date(timeIntervalSince1970: 59)),
            "------"
        )
    }

    func testGenerateCodeReturnsPlaceholderForInvalidBase32Secret() {
        let config = TOTPConfig(secret: encryptSecret("not_base32***"), period: 30, digits: 6, algorithm: .sha1)

        let code = TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(code, "------")
    }

    func testGenerateCodeClampsRoguePeriodAndDigits() {
        // Configs normally arrive sanitized from the parser, but edit drafts
        // construct them too: a non-positive period must not divide by zero
        // (or trap converting to UInt64), and oversized digit counts must not
        // overflow the 10^digits modulus.
        for period in [0, -5] {
            let config = TOTPConfig(secret: encryptSecret("JBSWY3DP"), period: period, digits: 6, algorithm: .sha1)
            XCTAssertNotEqual(
                TOTPGenerator.generateCode(config: config, sessionKey: testKey, date: Date(timeIntervalSince1970: 59)),
                "------"
            )
        }

        let oversizedDigits = TOTPConfig(secret: encryptSecret("JBSWY3DP"), period: 30, digits: 20, algorithm: .sha1)
        let code = TOTPGenerator.generateCode(
            config: oversizedDigits, sessionKey: testKey, date: Date(timeIntervalSince1970: 59)
        )
        XCTAssertEqual(code.count, 9)

        XCTAssertEqual(TOTPGenerator.secondsRemaining(period: 0, date: Date(timeIntervalSince1970: 74)), 1)
    }

    func testSecondsRemainingAtBoundaryReturnsFullPeriod() {
        let date = Date(timeIntervalSince1970: 60)

        let remaining = TOTPGenerator.secondsRemaining(period: 30, date: date)

        XCTAssertEqual(remaining, 30)
    }

    func testSecondsRemainingMidPeriodReturnsExpectedValue() {
        let date = Date(timeIntervalSince1970: 74)

        let remaining = TOTPGenerator.secondsRemaining(period: 30, date: date)

        XCTAssertEqual(remaining, 16)
    }

    func testBase32DecodeAcceptsLowercaseWhitespaceAndPadding() throws {
        let canonical = try XCTUnwrap(TOTPGenerator.base32Decode("JBSWY3DPEHPK3PXP"))
        let normalized = try XCTUnwrap(TOTPGenerator.base32Decode("jbsw y3dp ehpk3pxp===="))

        XCTAssertEqual(normalized, canonical)
    }

    func testBase32DecodeRejectsInvalidCharacters() {
        XCTAssertNil(TOTPGenerator.base32Decode("ABC$DEF"))
    }
}
