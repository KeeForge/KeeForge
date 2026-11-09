import Foundation

/// Budget for executing an attacker-controlled Argon2 configuration.
/// Format validity is checked separately; this bounds local resource use only.
public struct KDFExecutionPolicy: Sendable, Hashable {
    /// Upper bound on the Argon2 memory parameter (peak allocation).
    public let maxPeakMemoryBytes: UInt64
    /// Upper bound on memory × iterations (total bytes processed), the real CPU cost proxy.
    public let maxTotalWorkBytes: UInt64
    /// Upper bound on Argon2 lanes/threads.
    public let maxParallelism: UInt32

    public init(maxPeakMemoryBytes: UInt64, maxTotalWorkBytes: UInt64, maxParallelism: UInt32) {
        self.maxPeakMemoryBytes = maxPeakMemoryBytes
        self.maxTotalWorkBytes = maxTotalWorkBytes
        self.maxParallelism = maxParallelism
    }

    /// The resource check `KDBXKeyDerivation.deriveKey` runs before Argon2.
    /// Callers that skip the KDF (for example with a cached transformed key)
    /// run it on the header before anything that will derive under this
    /// policy, such as a save. AES-KDF and unknown KDFs pass.
    public func validate(kdfParameters: KDBXVariantMap) throws {
        guard case .argon2(let argon2)? = KDBXKeyDerivation(parameters: kdfParameters) else { return }
        try validate(iterations: argon2.iterations, memoryBytes: argon2.memoryBytes, parallelism: argon2.parallelism)
    }

    /// Exact stored values run or are rejected, never clamped.
    public func validate(iterations: UInt64, memoryBytes: UInt64, parallelism: UInt32) throws {
        let (totalWork, overflow) = memoryBytes.multipliedReportingOverflow(by: iterations)
        guard memoryBytes <= maxPeakMemoryBytes,
              !overflow, totalWork <= maxTotalWorkBytes,
              parallelism <= maxParallelism else {
            throw KDBXContainer.ParseError.kdfResourceLimitExceeded(
                iterations: iterations,
                memoryBytes: memoryBytes,
                parallelism: parallelism
            )
        }
    }
}
