import XCTest
@testable import KeeForge

/// Covers the pre-flight that stops the AutoFill extension from starting a key
/// derivation it cannot survive. The failure it guards against is a process
/// kill, so there is no error to observe after the fact — the check has to be
/// right before Argon2 allocates.
final class AutoFillMemoryLimitTests: XCTestCase {

    private let megabyte: UInt64 = 1024 * 1024

    private func summary(argon2MemoryBytes: UInt64) -> KDBXFileSummary {
        KDBXFileSummary(
            formatVersion: .kdbx4(minor: 0),
            cipher: .aes256CBC,
            isCompressed: true,
            keyDerivation: .argon2id(iterations: 3, memoryBytes: argon2MemoryBytes, parallelism: 2)
        )
    }

    func testRejectsArgon2MemoryLargerThanTheRemainingBudget() {
        let fileBytes = 2 * Int(megabyte)
        let remaining = 120 * megabyte

        XCTAssertThrowsError(
            try AutoFillMemoryLimit.check(
                databaseByteCount: fileBytes,
                summary: summary(argon2MemoryBytes: 1024 * megabyte),
                remainingBytes: remaining
            )
        ) { error in
            let exceeded = error as? AutoFillMemoryLimit.BudgetExceeded
            XCTAssertEqual(
                exceeded,
                AutoFillMemoryLimit.BudgetExceeded(
                    requiredBytes: 1024 * megabyte + UInt64(fileBytes) + AutoFillMemoryLimit.parseReserveBytes,
                    availableBytes: remaining
                )
            )
            XCTAssertFalse(exceeded?.errorDescription?.isEmpty ?? true, "The user has to be told what went wrong")
        }
    }

    func testAcceptsATypicalDatabaseThatFitsTheBudget() throws {
        try AutoFillMemoryLimit.check(
            databaseByteCount: 2 * Int(megabyte),
            summary: summary(argon2MemoryBytes: 64 * megabyte),
            remainingBytes: 300 * megabyte
        )
    }

    /// The reserve is what separates "fits exactly" from "fits with room to
    /// decrypt and parse", so it must be part of the comparison.
    func testCountsTheParseReserveAgainstTheBudget() {
        let argon2Memory = 64 * megabyte
        let fileBytes = Int(megabyte)
        let remainingWithoutReserve = argon2Memory + UInt64(fileBytes)

        XCTAssertThrowsError(
            try AutoFillMemoryLimit.check(
                databaseByteCount: fileBytes,
                summary: summary(argon2MemoryBytes: argon2Memory),
                remainingBytes: remainingWithoutReserve
            )
        )

        XCTAssertNoThrow(
            try AutoFillMemoryLimit.check(
                databaseByteCount: fileBytes,
                summary: summary(argon2MemoryBytes: argon2Memory),
                remainingBytes: remainingWithoutReserve + AutoFillMemoryLimit.parseReserveBytes
            )
        )
    }

    /// AES-KDF spends rounds, not memory, so it must not be rejected on a
    /// budget that only Argon2 could exhaust.
    func testAESKDFContributesNoMemoryRequirement() throws {
        let summary = KDBXFileSummary(
            formatVersion: .kdbx3_1,
            cipher: .aes256CBC,
            isCompressed: true,
            keyDerivation: .aesKDF(rounds: 100_000_000)
        )

        try AutoFillMemoryLimit.check(
            databaseByteCount: Int(megabyte),
            summary: summary,
            remainingBytes: 64 * megabyte
        )
    }

    /// The header's memory parameter is not range-checked until the derivation
    /// itself, so a hostile or corrupt `M` reaches this check unbounded. It has
    /// to be rejected, not overflow the sum and trap.
    func testAbsurdHeaderMemoryIsRejectedWithoutOverflowing() {
        XCTAssertThrowsError(
            try AutoFillMemoryLimit.check(
                databaseByteCount: Int(megabyte),
                summary: summary(argon2MemoryBytes: .max),
                remainingBytes: 120 * megabyte
            )
        ) { error in
            XCTAssertEqual((error as? AutoFillMemoryLimit.BudgetExceeded)?.requiredBytes, .max)
        }
    }

    /// A process the system reports no limit for must never be blocked — that
    /// is the app and macOS case, where the extension budget does not apply.
    func testUnreportedBudgetSkipsTheCheck() throws {
        try AutoFillMemoryLimit.check(
            databaseByteCount: 64 * Int(megabyte),
            summary: summary(argon2MemoryBytes: 4096 * megabyte),
            remainingBytes: 0
        )
    }
}
