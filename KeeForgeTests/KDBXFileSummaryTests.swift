import XCTest
@testable import KeeForge

final class KDBXFileSummaryTests: XCTestCase {
    private func fixtureData(named name: String) throws -> Data {
        let bundle = Bundle(for: KDBXFileSummaryTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "kdbx"))
        return try Data(contentsOf: url)
    }

    func testInspectKDBX4Fixture() throws {
        let summary = try KDBXFileSummary.inspect(data: fixtureData(named: "test"))

        XCTAssertEqual(summary.formatVersion, .kdbx4(minor: 0))
        XCTAssertEqual(summary.formatDisplayName, "KDBX 4.0")
        XCTAssertEqual(summary.cipher, .aes256CBC)
        XCTAssertEqual(summary.cipherDisplayName, "AES-256")
        XCTAssertTrue(summary.isCompressed)
        XCTAssertEqual(
            summary.keyDerivation,
            .argon2d(iterations: 14, memoryBytes: 64 * 1024 * 1024, parallelism: 2)
        )
        XCTAssertEqual(summary.keyDerivationDisplayName, "Argon2d")
        XCTAssertNotNil(summary.keyDerivationDetailText)
    }

    func testInspectKDBX3Fixture() throws {
        let summary = try KDBXFileSummary.inspect(data: fixtureData(named: "test-v3-backup"))

        XCTAssertEqual(summary.formatVersion, .kdbx3_1)
        XCTAssertEqual(summary.formatDisplayName, "KDBX 3.1")
        XCTAssertEqual(summary.cipher, .aes256CBC)
        XCTAssertTrue(summary.isCompressed)
        XCTAssertEqual(summary.keyDerivation, .aesKDF(rounds: 1_000_000))
        XCTAssertEqual(summary.keyDerivationDisplayName, "AES-KDF")
    }

    func testInspectAcceptsHeaderPrefixOnly() throws {
        // The details sheet reads only a bounded prefix of the file; the full
        // outer header of the fixtures fits comfortably within 1 KiB.
        let prefix = Data(try fixtureData(named: "test").prefix(1024))

        let summary = try KDBXFileSummary.inspect(data: prefix)

        XCTAssertEqual(summary.formatVersion, .kdbx4(minor: 0))
        XCTAssertEqual(summary.cipher, .aes256CBC)
    }

    func testInspectRejectsNonKDBXData() {
        XCTAssertThrowsError(try KDBXFileSummary.inspect(data: Data(repeating: 0xAB, count: 128)))
        XCTAssertThrowsError(try KDBXFileSummary.inspect(data: Data()))
    }
}
