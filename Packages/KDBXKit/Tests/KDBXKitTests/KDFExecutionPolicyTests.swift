import XCTest
@testable import KDBXKit

final class KDFExecutionPolicyTests: XCTestCase {
    private let policy = KDFExecutionPolicy(maxPeakMemoryBytes: 1000, maxTotalWorkBytes: 5000, maxParallelism: 4)

    private func exceeded(_ iterations: UInt64, _ memory: UInt64, _ parallelism: UInt32) -> KDBXContainer.ParseError {
        .kdfResourceLimitExceeded(iterations: iterations, memoryBytes: memory, parallelism: parallelism)
    }

    func testStoresItsLimits() {
        XCTAssertEqual(policy.maxPeakMemoryBytes, 1000)
        XCTAssertEqual(policy.maxTotalWorkBytes, 5000)
        XCTAssertEqual(policy.maxParallelism, 4)
    }

    func testAcceptsValuesAtEveryLimit() throws {
        try policy.validate(iterations: 5, memoryBytes: 1000, parallelism: 4)
        try policy.validate(iterations: 0, memoryBytes: 0, parallelism: 0)
    }

    func testRejectsEachLimitExceededAlone() {
        assertThrows(exceeded(1, 1001, 1)) { try self.policy.validate(iterations: 1, memoryBytes: 1001, parallelism: 1) }
        assertThrows(exceeded(6, 1000, 1)) { try self.policy.validate(iterations: 6, memoryBytes: 1000, parallelism: 1) }
        assertThrows(exceeded(1, 1, 5)) { try self.policy.validate(iterations: 1, memoryBytes: 1, parallelism: 5) }
    }

    /// memory × iterations overflowing UInt64 must not wrap into a small product.
    func testRejectsOverflowingWork() {
        let unbounded = KDFExecutionPolicy(maxPeakMemoryBytes: .max, maxTotalWorkBytes: .max, maxParallelism: .max)
        XCTAssertNoThrow(try unbounded.validate(iterations: 1, memoryBytes: .max, parallelism: 1))
        assertThrows(exceeded(1 << 33, 1 << 31, 1)) {
            try unbounded.validate(iterations: 1 << 33, memoryBytes: 1 << 31, parallelism: 1)
        }
        assertThrows(exceeded(2, .max, 1)) {
            try unbounded.validate(iterations: 2, memoryBytes: .max, parallelism: 1)
        }
    }

    func testValidatesArgon2KDFParameters() {
        let argon2 = KDBXKeyDerivation.argon2(.init(variant: .d, iterations: 2, memoryBytes: 1000, parallelism: 1, salt: nil))
        XCTAssertNoThrow(try policy.validate(kdfParameters: argon2.parameters))

        let heavy = KDBXKeyDerivation.argon2(.init(variant: .id, iterations: 6, memoryBytes: 1000, parallelism: 1, salt: nil))
        assertThrows(exceeded(6, 1000, 1)) { try self.policy.validate(kdfParameters: heavy.parameters) }

        // Defaults apply to missing values, as when deriving.
        let defaults: KDBXVariantMap = ["$UUID": .bytes(KDBXKeyDerivation.Algorithm.argon2d.uuid)]
        assertThrows(exceeded(3, 64 * 1024 * 1024, 1)) { try self.policy.validate(kdfParameters: defaults) }
    }

    func testPassesAESKDFAndUnknownKDFs() throws {
        try policy.validate(kdfParameters: KDBXKeyDerivation.aesKDF(rounds: .max, seed: nil).parameters)
        try policy.validate(kdfParameters: ["$UUID": .bytes(Data(count: 16))])
        try policy.validate(kdfParameters: [:])
    }

    // MARK: - Enforced by deriveKey

    private func deriveArgon2(iterations: UInt64, memory: UInt64, policy: KDFExecutionPolicy) throws -> Data {
        try KDBXKeyDerivation.deriveKey(
            compositeKey: KDBXCrypto.compositeKey(password: "policy"),
            parameters: KDBXKeyDerivation.argon2(.init(
                variant: .id, iterations: iterations, memoryBytes: memory, parallelism: 1, salt: Data(count: 16)
            )).parameters,
            policy: policy
        )
    }

    func testDeriveKeyPeakMemoryBoundaryIsInclusive() throws {
        let policy = KDFExecutionPolicy(maxPeakMemoryBytes: 2 << 20, maxTotalWorkBytes: .max, maxParallelism: 16)
        XCTAssertEqual(try deriveArgon2(iterations: 1, memory: 2 << 20, policy: policy).count, 32)
        assertThrows(exceeded(1, (2 << 20) + 1, 1)) {
            try self.deriveArgon2(iterations: 1, memory: (2 << 20) + 1, policy: policy)
        }
    }

    func testDeriveKeyTotalWorkBoundaryIsInclusive() throws {
        let policy = KDFExecutionPolicy(maxPeakMemoryBytes: 1 << 20, maxTotalWorkBytes: 3 << 20, maxParallelism: 4)
        XCTAssertEqual(try deriveArgon2(iterations: 3, memory: 1 << 20, policy: policy).count, 32)
        assertThrows(exceeded(4, 1 << 20, 1)) { try self.deriveArgon2(iterations: 4, memory: 1 << 20, policy: policy) }
    }

    func testDeriveKeyRejectsOverflowingWorkWithoutTrapping() {
        let unbounded = KDFExecutionPolicy(maxPeakMemoryBytes: .max, maxTotalWorkBytes: .max, maxParallelism: 64)
        assertThrows(exceeded(1 << 25, 1 << 40, 1)) { try self.deriveArgon2(iterations: 1 << 25, memory: 1 << 40, policy: unbounded) }
    }
}
