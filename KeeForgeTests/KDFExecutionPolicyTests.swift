import CryptoKit
import XCTest
import KDBXKit
@testable import KeeForge

/// The app's and AutoFill's `KDFExecutionPolicy` presets as enforced by
/// `KDBXKeyDerivation.deriveKey`. Rejections happen before any derivation, so
/// rejection tests are free; acceptance tests perform a real derivation and
/// keep memory small so the whole suite stays fast.
final class KDFExecutionPolicyTests: XCTestCase {
    private let compositeKey = SymmetricKey(data: Data("kdf-policy-composite-key".utf8))

    private func argon2Params(
        iterations: UInt64,
        memory: UInt64,
        parallelism: UInt32,
        version: UInt32? = 0x13
    ) -> KDBXVariantMap {
        var params: KDBXVariantMap = [
            "$UUID": .bytes(KDBXKeyDerivation.Algorithm.argon2id.uuid),
            "I": .uint64(iterations),
            "M": .uint64(memory),
            "P": .uint32(parallelism),
            "S": .bytes(Data((0..<32).map { UInt8($0) })),
        ]
        if let version {
            params["V"] = .uint32(version)
        }
        return params
    }

    private func derive(_ params: KDBXVariantMap, policy: KDFExecutionPolicy) throws -> Data {
        try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: params, policy: policy)
    }

    private func assertResourceLimitExceeded(
        _ params: KDBXVariantMap,
        policy: KDFExecutionPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try derive(params, policy: policy), file: file, line: line) { error in
            guard case KDBXContainer.ParseError.kdfResourceLimitExceeded = error else {
                XCTFail("Expected kdfResourceLimitExceeded, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func assertParameterOutOfRange(
        _ params: KDBXVariantMap,
        policy: KDFExecutionPolicy,
        messageContains fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try derive(params, policy: policy), file: file, line: line) { error in
            guard case KDBXContainer.ParseError.kdfParameterOutOfRange(let message) = error else {
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

    func testEveryCreationPresetDerivesUnderTheAutoFillPolicy() throws {
        // Every creation preset must pass the AutoFill extension's policy, which
        // the creation flow verifies against. Admission there implies admission
        // under .mainApp, whose only difference is a higher peak-memory ceiling.
        for preset in DatabaseCreationKDFPreset.allCases {
            let params = argon2Params(
                iterations: preset.iterations,
                memory: preset.memoryBytes,
                parallelism: 4
            )
            let extensionKey = try derive(params, policy: .autoFillExtension)
            XCTAssertEqual(extensionKey.count, 32, "\(preset.rawValue)")
        }
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

    // MARK: - Total work budget

    func testExcessiveTotalWorkRejectedDespiteLowPeakMemory() {
        // 1 MiB x 5M iterations is ~4.8 TiB of processing behind a tiny allocation.
        assertResourceLimitExceeded(
            argon2Params(iterations: 5_000_000, memory: 1 << 20, parallelism: 1),
            policy: .mainApp
        )
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

    func testParallelismAbovePolicyRejectedPerPolicy() {
        // 257 lanes need >= 2056 KiB under the m >= 8p spec rule; 4 MiB keeps
        // the policy check, not the format check, as what fires.
        let params = argon2Params(iterations: 1, memory: 4 << 20, parallelism: 257)
        assertResourceLimitExceeded(params, policy: .mainApp)
        assertResourceLimitExceeded(params, policy: .autoFillExtension)
    }

    // MARK: - Argon2 version byte

}
