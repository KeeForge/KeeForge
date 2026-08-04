import XCTest
@testable import KeeForge

/// Covers the pre-flight that stops the AutoFill extension from starting a key
/// derivation it cannot survive. The failure it guards against is a process
/// kill, so there is no error to observe after the fact — the check has to be
/// right before Argon2 allocates.
///
/// The other half of "right" is refusing nothing else. A false refusal breaks a
/// vault that opens today, so every case below that is *not* a single
/// allocation larger than the remaining budget has to pass.
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
        let remaining = 120 * megabyte

        XCTAssertThrowsError(
            try AutoFillMemoryLimit.check(
                summary: summary(argon2MemoryBytes: 1024 * megabyte),
                remainingBytes: remaining
            )
        ) { error in
            let exceeded = error as? AutoFillMemoryLimit.BudgetExceeded
            XCTAssertEqual(
                exceeded,
                AutoFillMemoryLimit.BudgetExceeded(
                    requiredBytes: 1024 * megabyte,
                    availableBytes: remaining
                )
            )
            XCTAssertFalse(exceeded?.errorDescription?.isEmpty ?? true, "The user has to be told what went wrong")
        }
    }

    func testAcceptsATypicalDatabaseThatFitsTheBudget() throws {
        try AutoFillMemoryLimit.check(
            summary: summary(argon2MemoryBytes: 64 * megabyte),
            remainingBytes: 300 * megabyte
        )
    }

    /// The boundary is the allocation itself, with nothing added on top. A
    /// derivation that exactly fits is not known to fail, so it must be allowed
    /// to try.
    func testAcceptsAnArgon2BlockThatExactlyFitsTheBudget() throws {
        let budget = 64 * megabyte

        try AutoFillMemoryLimit.check(
            summary: summary(argon2MemoryBytes: budget),
            remainingBytes: budget
        )

        XCTAssertThrowsError(
            try AutoFillMemoryLimit.check(
                summary: summary(argon2MemoryBytes: budget + 1),
                remainingBytes: budget
            ),
            "one byte over the budget is one byte the allocation cannot have"
        )
    }

    /// The decrypt and parse that follow the derivation are a later peak, after
    /// the KDF block is freed. Pricing them here would refuse large databases
    /// that open today, so a vault whose *derivation* fits must pass no matter
    /// how big the file behind it is.
    func testDoesNotPriceTheParseThatFollowsTheDerivation() throws {
        try AutoFillMemoryLimit.check(
            summary: summary(argon2MemoryBytes: 64 * megabyte),
            remainingBytes: 64 * megabyte + 1
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

        try AutoFillMemoryLimit.check(summary: summary, remainingBytes: 64 * megabyte)
    }

    /// A KDF this build does not recognize gets the benefit of the doubt: its
    /// memory cost is unknown, and refusing on a guess is the one outcome worse
    /// than the bug.
    func testUnknownKDFIsNotRejected() throws {
        let summary = KDBXFileSummary(
            formatVersion: .kdbx4(minor: 0),
            cipher: .aes256CBC,
            isCompressed: true,
            keyDerivation: .unknown
        )

        try AutoFillMemoryLimit.check(summary: summary, remainingBytes: megabyte)
    }

    /// The header's memory parameter is not range-checked until the derivation
    /// itself, so a hostile or corrupt `M` reaches this check unbounded. It is
    /// compared rather than summed, so it must be reported verbatim instead of
    /// saturating or trapping.
    func testAbsurdHeaderMemoryIsRejectedWithoutOverflowing() {
        XCTAssertThrowsError(
            try AutoFillMemoryLimit.check(
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
            summary: summary(argon2MemoryBytes: 4096 * megabyte),
            remainingBytes: 0
        )
    }
}
