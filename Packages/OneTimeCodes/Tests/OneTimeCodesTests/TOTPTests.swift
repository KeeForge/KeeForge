import CryptoKit
import Foundation
import XCTest
@testable import OneTimeCodes

final class TOTPTests: XCTestCase {
    /// RFC 4226 Appendix D: the ASCII secret "12345678901234567890".
    private static let rfc4226Secret = Data("12345678901234567890".utf8)

    /// RFC 6238 Appendix B seeds: that string repeated to 20, 32, and 64 bytes.
    private static func rfc6238Seed(_ algorithm: TOTPAlgorithm) -> Data {
        let length = switch algorithm {
        case .sha1: 20
        case .sha256: 32
        case .sha512: 64
        }
        return Data((0..<length).map { Array("1234567890".utf8)[$0 % 10] })
    }

    private func parameters(
        _ secret: some ContiguousBytes, period: Int = 30, digits: Int = 6, algorithm: TOTPAlgorithm = .sha1
    ) throws -> TOTPParameters {
        try XCTUnwrap(TOTPParameters(secret: secret, period: period, digits: digits, algorithm: algorithm))
    }

    // MARK: - RFC 4226 (HOTP)

    func testHOTPMatchesRFC4226AppendixDTruncatedValuesAndCodes() {
        let key = SymmetricKey(data: Self.rfc4226Secret)
        let truncated: [UInt32] = [
            1_284_755_224, 1_094_287_082, 137_359_152, 1_726_969_429, 1_640_338_314,
            868_254_676, 1_918_287_922, 82_162_583, 673_399_871, 645_520_489,
        ]
        let codes = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]

        for counter in 0..<10 {
            XCTAssertEqual(
                HOTP.truncatedValue(key: key, counter: UInt64(counter), algorithm: .sha1),
                truncated[counter],
                "RFC 4226 truncated value at count \(counter)"
            )
            XCTAssertEqual(
                HOTP.code(key: key, counter: UInt64(counter), digits: 6, algorithm: .sha1),
                codes[counter],
                "RFC 4226 HOTP value at count \(counter)"
            )
        }
    }

    // MARK: - RFC 6238 (TOTP)

    func testTOTPMatchesTheFullRFC6238AppendixBTable() throws {
        let table: [(time: TimeInterval, algorithm: TOTPAlgorithm, code: String)] = [
            (59, .sha1, "94287082"), (59, .sha256, "46119246"), (59, .sha512, "90693936"),
            (1_111_111_109, .sha1, "07081804"), (1_111_111_109, .sha256, "68084774"), (1_111_111_109, .sha512, "25091201"),
            (1_111_111_111, .sha1, "14050471"), (1_111_111_111, .sha256, "67062674"), (1_111_111_111, .sha512, "99943326"),
            (1_234_567_890, .sha1, "89005924"), (1_234_567_890, .sha256, "91819424"), (1_234_567_890, .sha512, "93441116"),
            (2_000_000_000, .sha1, "69279037"), (2_000_000_000, .sha256, "90698825"), (2_000_000_000, .sha512, "38618901"),
            (20_000_000_000, .sha1, "65353130"), (20_000_000_000, .sha256, "77737706"), (20_000_000_000, .sha512, "47863826"),
        ]

        for row in table {
            let parameters = try parameters(Self.rfc6238Seed(row.algorithm), digits: 8, algorithm: row.algorithm)
            XCTAssertEqual(
                TOTP.code(for: parameters, at: Date(timeIntervalSince1970: row.time)),
                row.code,
                "RFC 6238 \(row.algorithm) at T=\(row.time)"
            )
        }
    }

    func testTOTPMatchesIndependentReferenceForArbitraryBinarySecret() throws {
        // Python hmac/hashlib SHA-1 at counter 1.
        let parameters = try parameters(Data([0x00, 0x01, 0x02, 0xFE, 0xFF]))

        XCTAssertEqual(TOTP.code(for: parameters, at: Date(timeIntervalSince1970: 59)), "388061")
    }

    func testCodesAreZeroPaddedToTheDigitCount() throws {
        // 1_094_287_082 is RFC 4226's truncated value at count 1; modulo 10^9 it has a leading zero.
        let parameters = try parameters(Self.rfc4226Secret, digits: 9)

        XCTAssertEqual(TOTP.code(for: parameters, at: Date(timeIntervalSince1970: 30)), "094287082")
    }

    func testParametersClampRoguePeriodAndDigits() throws {
        for period in [0, -5] {
            let parameters = try parameters(Self.rfc4226Secret, period: period, digits: 8)
            XCTAssertEqual(parameters.period, 1)
            // T=1 with a one-second step is counter 1.
            XCTAssertEqual(TOTP.code(for: parameters, at: Date(timeIntervalSince1970: 1)), "94287082")
        }

        let oversized = try parameters(Self.rfc4226Secret, digits: 20)
        XCTAssertEqual(oversized.digits, 9)
        XCTAssertEqual(TOTP.code(for: oversized, at: Date(timeIntervalSince1970: 59)), "094287082")

        let undersized = try parameters(Self.rfc4226Secret, digits: 0)
        XCTAssertEqual(undersized.digits, 1)
        XCTAssertEqual(TOTP.code(for: undersized, at: Date(timeIntervalSince1970: 59)), "2")
    }

    func testParametersRejectAnEmptySecretAndKeepTheirValues() throws {
        XCTAssertNil(TOTPParameters(secret: Data()))

        let parameters = try parameters(Data([1, 2, 3]), period: 45, digits: 7, algorithm: .sha256)
        XCTAssertEqual(parameters.period, 45)
        XCTAssertEqual(parameters.digits, 7)
        XCTAssertEqual(parameters.algorithm, .sha256)
        XCTAssertEqual(parameters.secret.withUnsafeBytes { Data($0) }, Data([1, 2, 3]))

        let defaults = try XCTUnwrap(TOTPParameters(secret: Data([1])))
        XCTAssertEqual(defaults.period, 30)
        XCTAssertEqual(defaults.digits, 6)
        XCTAssertEqual(defaults.algorithm, .sha1)
    }

    func testDatesBefore1970UseTheFirstTimeStep() throws {
        let parameters = try parameters(Self.rfc4226Secret)

        XCTAssertEqual(TOTP.code(for: parameters, at: Date(timeIntervalSince1970: -100)), "755224")
    }

    func testSecondsRemaining() {
        XCTAssertEqual(TOTP.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 60)), 30, "boundary")
        XCTAssertEqual(TOTP.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 74)), 16)
        XCTAssertEqual(TOTP.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 89.9)), 1)
        XCTAssertEqual(TOTP.secondsRemaining(period: 0, at: Date(timeIntervalSince1970: 74)), 1)
        XCTAssertEqual(TOTP.secondsRemaining(period: -5, at: Date(timeIntervalSince1970: 74)), 1)
    }

    // MARK: - Algorithm names

    func testAlgorithmRawValuesAreThePersistedTokens() throws {
        XCTAssertEqual(TOTPAlgorithm.allCases.map(\.rawValue), ["SHA1", "SHA256", "SHA512"])

        let encoded = try JSONEncoder().encode([TOTPAlgorithm.sha1, .sha256, .sha512])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["SHA1","SHA256","SHA512"]"#)
        XCTAssertEqual(try JSONDecoder().decode([TOTPAlgorithm].self, from: encoded), [.sha1, .sha256, .sha512])
    }

    func testAlgorithmKeePassNames() {
        XCTAssertEqual(TOTPAlgorithm.allCases.map(\.keePassName), ["HMAC-SHA-1", "HMAC-SHA-256", "HMAC-SHA-512"])
        for algorithm in TOTPAlgorithm.allCases {
            XCTAssertEqual(TOTPAlgorithm(keePassName: algorithm.keePassName), algorithm)
            XCTAssertEqual(TOTPAlgorithm(keePassName: algorithm.rawValue), algorithm)
        }
        XCTAssertNil(TOTPAlgorithm(keePassName: "hmac-sha-1"), "KeePass matches names exactly")
        XCTAssertNil(TOTPAlgorithm(keePassName: "HMAC-MD5"))
    }
}
