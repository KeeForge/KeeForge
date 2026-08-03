import XCTest
@testable import KeeForge

/// Boundary coverage for `KDFExecutionPolicy` enforcement in
/// `KDBXParser.deriveKey`. Rejections happen before any derivation, so
/// rejection tests are free; acceptance tests perform a real derivation and
/// keep memory small so the whole suite stays fast.
final class KDFExecutionPolicyTests: XCTestCase {
    private let compositeKey = Data("kdf-policy-composite-key".utf8)

    private func argon2Params(
        iterations: UInt64,
        memory: UInt64,
        parallelism: UInt32,
        version: UInt32? = 0x13
    ) -> [String: Any] {
        var params: [String: Any] = [
            "$UUID": KDBXParser.argon2idUUID,
            "I": iterations,
            "M": memory,
            "P": parallelism,
            "S": Data((0..<32).map { UInt8($0) }),
        ]
        if let version {
            params["V"] = version
        }
        return params
    }

    private func derive(_ params: [String: Any], policy: KDFExecutionPolicy) throws -> Data {
        try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: params, kdfPolicy: policy)
    }

    private func assertResourceLimitExceeded(
        _ params: [String: Any],
        policy: KDFExecutionPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try derive(params, policy: policy), file: file, line: line) { error in
            guard case KDBXParser.ParseError.kdfResourceLimitExceeded = error else {
                XCTFail("Expected kdfResourceLimitExceeded, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func assertParameterOutOfRange(
        _ params: [String: Any],
        policy: KDFExecutionPolicy,
        messageContains fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try derive(params, policy: policy), file: file, line: line) { error in
            guard case KDBXParser.ParseError.kdfParameterOutOfRange(let message) = error else {
                XCTFail("Expected kdfParameterOutOfRange, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(
                message.contains(fragment),
                "Expected message containing \(fragment), got: \(message)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Acceptance

    func testHighIterationsWithLowMemoryDeriveUnderBothPolicies() throws {
        // Issue #74 headline case: above the retired fixed 1000-iteration cap,
        // but only ~75 MiB of total work.
        let params = argon2Params(iterations: 1200, memory: 64 * 1024, parallelism: 1)
        let mainAppKey = try derive(params, policy: .mainApp)
        let extensionKey = try derive(params, policy: .autoFillExtension)
        XCTAssertEqual(mainAppKey.count, 32)
        XCTAssertEqual(mainAppKey, extensionKey)
    }

    func testCreationProfileDerivesUnderBothPolicies() throws {
        // KeeForge's own new-database profile must comfortably pass both.
        let params = argon2Params(iterations: 10, memory: 64 * 1024 * 1024, parallelism: 4)
        let mainAppKey = try derive(params, policy: .mainApp)
        let extensionKey = try derive(params, policy: .autoFillExtension)
        XCTAssertEqual(mainAppKey.count, 32)
        XCTAssertEqual(mainAppKey, extensionKey)
    }

    // MARK: - Peak memory budget

    func testExcessivePeakMemoryRejectedEvenWithSingleIteration() {
        assertResourceLimitExceeded(
            argon2Params(iterations: 1, memory: 8 << 30, parallelism: 1),
            policy: .mainApp
        )
    }

    func testPeakMemoryLimitSeparatesAppFromExtension() throws {
        let params = argon2Params(iterations: 1, memory: (512 << 20) + (1 << 20), parallelism: 1)
        assertResourceLimitExceeded(params, policy: .autoFillExtension)
        XCTAssertEqual(try derive(params, policy: .mainApp).count, 32)
    }

    func testPeakMemoryBoundaryIsInclusive() throws {
        // Synthetic policy keeps the at-limit derivation cheap; the comparison
        // under test is the same one the shipped policies run.
        let policy = KDFExecutionPolicy(
            maxPeakMemoryBytes: 2 << 20,
            maxTotalWorkBytes: .max,
            maxParallelism: 16
        )
        let atLimit = argon2Params(iterations: 1, memory: 2 << 20, parallelism: 1)
        XCTAssertEqual(try derive(atLimit, policy: policy).count, 32)

        // The comparison is on the raw byte value, so one byte over rejects.
        assertResourceLimitExceeded(
            argon2Params(iterations: 1, memory: (2 << 20) + 1, parallelism: 1),
            policy: policy
        )
    }

    // MARK: - Total work budget

    func testExcessiveTotalWorkRejectedDespiteLowPeakMemory() {
        // 1 MiB x 5M iterations is ~4.8 TiB of processing behind a tiny allocation.
        assertResourceLimitExceeded(
            argon2Params(iterations: 5_000_000, memory: 1 << 20, parallelism: 1),
            policy: .mainApp
        )
    }

    func testTotalWorkBoundaryIsInclusive() throws {
        // Deriving exactly 4 GiB of work to prove the extension's boundary is
        // inclusive would dominate the suite's runtime, so the comparison
        // semantics are proven on a synthetic policy at a cheap scale and the
        // shipped constants are pinned separately below.
        let policy = KDFExecutionPolicy(
            maxPeakMemoryBytes: 1 << 20,
            maxTotalWorkBytes: 3 << 20,
            maxParallelism: 4
        )
        let atLimit = argon2Params(iterations: 3, memory: 1 << 20, parallelism: 1)
        XCTAssertEqual(try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: atLimit, kdfPolicy: policy).count, 32)

        let overLimit = argon2Params(iterations: 4, memory: 1 << 20, parallelism: 1)
        XCTAssertThrowsError(
            try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: overLimit, kdfPolicy: policy)
        ) { error in
            guard case KDBXParser.ParseError.kdfResourceLimitExceeded = error else {
                XCTFail("Expected kdfResourceLimitExceeded, got \(error)")
                return
            }
        }
    }

    func testShippedPolicyConstants() {
        // The policies must differ ONLY in peak memory: work and parallelism
        // asymmetry would let the static policy refuse a vault in one context
        // that the other opens, which is AutoFillMemoryLimit's job to decide.
        XCTAssertEqual(KDFExecutionPolicy.mainApp.maxPeakMemoryBytes, 1 << 32)
        XCTAssertEqual(KDFExecutionPolicy.autoFillExtension.maxPeakMemoryBytes, 512 << 20)
        XCTAssertEqual(KDFExecutionPolicy.mainApp.maxTotalWorkBytes, 64 << 30)
        XCTAssertEqual(KDFExecutionPolicy.autoFillExtension.maxTotalWorkBytes, KDFExecutionPolicy.mainApp.maxTotalWorkBytes)
        XCTAssertEqual(KDFExecutionPolicy.mainApp.maxParallelism, 256)
        XCTAssertEqual(KDFExecutionPolicy.autoFillExtension.maxParallelism, KDFExecutionPolicy.mainApp.maxParallelism)
    }

    func testWorkProductOverflowRejectedWithoutCrash() {
        // memory x iterations overflows UInt64 (2^40 x 2^25 = 2^65). A synthetic
        // unbounded policy bypasses the peak-memory guard so the overflow-checked
        // multiply itself must reject, never wrap around or trap.
        let unbounded = KDFExecutionPolicy(
            maxPeakMemoryBytes: .max,
            maxTotalWorkBytes: .max,
            maxParallelism: 64
        )
        assertResourceLimitExceeded(
            argon2Params(iterations: 1 << 25, memory: 1 << 40, parallelism: 1),
            policy: unbounded
        )
        assertResourceLimitExceeded(
            argon2Params(iterations: 1 << 25, memory: 1 << 40, parallelism: 1),
            policy: .mainApp
        )
    }

    // MARK: - Format validation (spec, not policy)

    func testZeroIterationsRejectedAsOutOfRange() {
        assertParameterOutOfRange(
            argon2Params(iterations: 0, memory: 1 << 20, parallelism: 1),
            policy: .mainApp,
            messageContains: "iterations"
        )
    }

    func testZeroParallelismRejectedAsOutOfRange() {
        assertParameterOutOfRange(
            argon2Params(iterations: 3, memory: 1 << 20, parallelism: 0),
            policy: .mainApp,
            messageContains: "parallelism"
        )
    }

    func testMemoryBelowLaneMinimumRejectedAsOutOfRange() {
        // RFC 9106 requires m >= 8p KiB: 16 lanes need at least 128 KiB.
        assertParameterOutOfRange(
            argon2Params(iterations: 3, memory: 64 * 1024, parallelism: 16),
            policy: .mainApp,
            messageContains: "memory"
        )
    }

    func testIterationsAboveUInt32RejectedAsResourceLimit() {
        // Under the shipped budgets such values are a resource rejection with
        // the actionable message; the defensive exact-UInt32 guard only fires
        // for a synthetic policy that waves the budgets through.
        let params = argon2Params(iterations: UInt64(UInt32.max) + 1, memory: 8192, parallelism: 1)
        assertResourceLimitExceeded(params, policy: .mainApp)
        assertParameterOutOfRange(
            params,
            policy: KDFExecutionPolicy(maxPeakMemoryBytes: .max, maxTotalWorkBytes: .max, maxParallelism: 256),
            messageContains: "iterations"
        )
    }

    func testMemoryKiBAboveUInt32RejectedAsResourceLimit() {
        let params = argon2Params(iterations: 1, memory: (UInt64(UInt32.max) + 1) * 1024, parallelism: 1)
        assertResourceLimitExceeded(params, policy: .mainApp)
        assertParameterOutOfRange(
            params,
            policy: KDFExecutionPolicy(maxPeakMemoryBytes: .max, maxTotalWorkBytes: .max, maxParallelism: 256),
            messageContains: "memory"
        )
    }

    func testParallelismAboveSpecMaximumRejectedAsOutOfRange() {
        assertParameterOutOfRange(
            argon2Params(iterations: 1, memory: 1 << 20, parallelism: 0x100_0000),
            policy: .mainApp,
            messageContains: "parallelism"
        )
    }

    func testParallelismAbovePolicyRejectedPerPolicy() {
        // 257 lanes need >= 2056 KiB under the m >= 8p spec rule; 4 MiB keeps
        // the policy check, not the format check, as what fires.
        let params = argon2Params(iterations: 1, memory: 4 << 20, parallelism: 257)
        assertResourceLimitExceeded(params, policy: .mainApp)
        assertResourceLimitExceeded(params, policy: .autoFillExtension)
    }

    // MARK: - Argon2 version byte

    func testArgon2Version10DerivesDifferentKeyThanVersion13() throws {
        let v13 = try derive(argon2Params(iterations: 3, memory: 64 * 1024, parallelism: 1, version: 0x13), policy: .mainApp)
        let v10 = try derive(argon2Params(iterations: 3, memory: 64 * 1024, parallelism: 1, version: 0x10), policy: .mainApp)
        XCTAssertEqual(v13.count, 32)
        XCTAssertEqual(v10.count, 32)
        XCTAssertNotEqual(v13, v10, "V=0x10 must actually change the derivation, not be silently treated as 0x13")
    }

    func testAbsentArgon2VersionDefaultsToVersion13() throws {
        let explicit = try derive(argon2Params(iterations: 3, memory: 64 * 1024, parallelism: 1, version: 0x13), policy: .mainApp)
        let absent = try derive(argon2Params(iterations: 3, memory: 64 * 1024, parallelism: 1, version: nil), policy: .mainApp)
        XCTAssertEqual(absent, explicit)
    }

    func testUnknownArgon2VersionRejectedAsOutOfRange() {
        assertParameterOutOfRange(
            argon2Params(iterations: 3, memory: 64 * 1024, parallelism: 1, version: 0x12),
            policy: .mainApp,
            messageContains: "version"
        )
    }
}
